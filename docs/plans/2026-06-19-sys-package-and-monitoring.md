# `lib/sys` Package + Real-Time Soft-Metric Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract `Hyper.Sys.*` into a standalone top-level `Sys.*` package under `lib/sys`, then add `Sys.Mon` — a supervised set of per-node monitors (`Cpu`, `Mem`, `DiskBw`, `NetBw`) that periodically sample instantaneous load and low-pass-filter it into an exponential moving average for the scheduler's soft-budget (β) decisions.

**Architecture:** Each monitor is one `Sys.Mon.Server` GenServer parameterized by a `Sys.Mon.Sampler` implementation. The sampler reads `/proc` directly (matching the existing `Sys.Linux.Proc.Mounts` precedent — no `:os_mon`). Each raw reading is folded into `Controls.Ewma`, a first-order discrete low-pass filter whose gain `α = 1 − exp(−Δt/τ)` is derived from the *measured* elapsed time, so the filter's cutoff is invariant to scheduler jitter and to the differing prime sample periods. Monitors emit `:telemetry` events and answer a synchronous `value/0` call returning instantaneous + smoothed readings in domain units (`Unit.Information`, `Unit.Bandwidth`).

**Tech Stack:** Elixir 1.20, OTP supervision, `:telemetry` (already in the lock via `horde`), `/proc` parsing, `Unit.*` value structs, ExUnit.

## Global Constraints

- **Elixir floor:** `~> 1.19` (mix.exs). Use the type system: every public function carries an `@spec`; every module a `@moduledoc`; every public function a `@doc`.
- **`mix check` is the gate** and must pass at the end: `format --check-formatted`, `compile --warnings-as-errors --force`, `credo --strict`, `test --warnings-as-errors`, `dialyzer`.
- **Dialyzer flags are strict:** `:unmatched_returns`, `:extra_return`, `:missing_return`. Never silently discard a non-trivial return value — bind it (`_ref = Process.send_after(...)`) or pattern-match it.
- **No new runtime OS deps:** monitors read `/proc` directly. Do **not** add `:os_mon`/`cpu_sup`/`memsup`. Rationale in "Research & Design Rationale" below.
- **LPF correctness:** the EWMA gain is computed from the measured `Δt` and a configured time constant `τ`. A hardcoded fixed `α` is forbidden.
- **Clocks:** all `Δt` measurements use `System.monotonic_time/1`. Never wall-clock (`:os.system_time`, `DateTime`).
- **License:** AGPL-3.0-or-later (unchanged; no per-file headers in this repo).
- **Top-level namespace:** the package is `Sys.*` (parallel to the existing `Unit.*` in `lib/unit`), **not** `Hyper.Sys.*`.

---

## Research & Design Rationale

This section is non-normative context for the implementer. Read it once; it explains *why* the tasks look the way they do and which tempting shortcuts are bugs.

### Why read `/proc` directly instead of a package

Candidate libraries were considered and rejected:

- **`:os_mon` (`cpu_sup`, `memsup`, `disksup`)** — OTP built-in. Rejected: it starts its own supervision tree, alarm handlers, and a `cpu_sup` port program; `cpu_sup:util/0`'s first call returns since-boot garbage and its semantics are per-caller and opaque; `memsup` runs its own collection loop with its own period we can't align to our filter. It hides exactly the timing we need to control.
- **`:telemetry_poller`** (already a transitive dep) — periodically invokes measurement functions and emits telemetry. Good for *fire-and-forget* sampling, but it holds no filter state and offers no synchronous getter, so we'd bolt a stateful handler beside it and still own most of the code. We reuse its *idea* (periodic measurement → telemetry) but own the loop so the EWMA state and the `value/0` getter live in one process.

The existing codebase already parses `/proc/mounts` by hand (`Sys.Linux.Proc.Mounts`). Following that precedent keeps the soft-metric path dependency-free, fully under our timing control, and unit-testable against fixture strings.

### The LPF / EWMA — the controls core, and the bad ideas to avoid

The continuous first-order low-pass filter `τ·ẏ + y = x` has the exact discrete solution, for a sample held over interval `Δt`:

```
α   = 1 − exp(−Δt/τ)
yₙ  = α·xₙ + (1−α)·yₙ₋₁
```

Pitfalls this plan deliberately avoids:

1. **Fixed `α` with variable `Δt` (the big one).** BEAM timers drift and each monitor uses a different prime period, so a constant `α` makes the filter's cutoff frequency ride on scheduler jitter. We derive `α` from the measured `Δt` every sample. `τ` (the time constant) is the only tuning knob: output reaches ~63 % of a step after `τ`, ~95 % after `3τ`.
2. **`/proc/loadavg` is not CPU utilization.** Load average counts runnable *and* uninterruptible-sleep tasks and is itself a kernel EWMA with fixed 1/5/15-min constants — wrong semantics and double-filtered. For β_vcpus we want the busy *fraction* from `/proc/stat` jiffy deltas.
3. **A single `/proc/stat` read is cumulative-since-boot.** Utilization needs two snapshots and a delta. The first sample has no predecessor, so it must be *skipped* (emit nothing) rather than reported as a bogus value.
4. **Cold-start bias.** Seeding the EWMA at `0` causes a long warm-up ramp. We seed with the first valid sample (`y₀ = x₀`).
5. **Wall clock for `Δt`.** NTP steps would corrupt the gain. Monotonic clock only.
6. **Timer backlog.** `:timer.send_interval` queues ticks even if a sample is slow. We self-schedule with `Process.send_after` *after* each sample completes, so a slow sample cannot pile up messages.
7. **Prime periods help only with sampling-phase de-correlation, not accuracy.** The control-relevant parameter is `τ` (and Nyquist: sample at least ~2× faster than the dynamics you want to track). We honor the prime-period request — `Cpu=2s, Mem=5s, DiskBw=7s, NetBw=11s` (pairwise coprime, so their tick phases rarely align) — but choose them with Nyquist in mind, not primality alone.
8. **Counter rate edge cases.** Disk/net bandwidth come from monotonically increasing byte counters. A reboot resets them; the first sample has no baseline. Both cases must *skip* rather than emit a negative or infinite rate.

### Value representation

CPU utilization is a dimensionless fraction `0.0..1.0` (busy time over wall time, normalized across all cores) — a plain float. Memory carries `Unit.Information`; disk/net bandwidth carry `Unit.Bandwidth` (bytes/sec). The EWMA math runs on raw floats internally; each monitor wraps the float back into its domain unit at the `value/0` boundary.

---

## File Structure

**Migration (Task 1) — move + rename `Hyper.Sys.*` → `Sys.*`:**

| From | To |
|------|----|
| `lib/hyper/sys/posix.ex` | `lib/sys/posix.ex` |
| `lib/hyper/sys/linux/cgroup.ex` | `lib/sys/linux/cgroup.ex` |
| `lib/hyper/sys/linux/cgroup/v2.ex` | `lib/sys/linux/cgroup/v2.ex` |
| `lib/hyper/sys/linux/dmsetup.ex` | `lib/sys/linux/dmsetup.ex` |
| `lib/hyper/sys/linux/fstab.ex` | `lib/sys/linux/fstab.ex` |
| `lib/hyper/sys/linux/losetup.ex` | `lib/sys/linux/losetup.ex` |
| `lib/hyper/sys/linux/nss.ex` | `lib/sys/linux/nss.ex` |
| `lib/hyper/sys/linux/proc/mounts.ex` | `lib/sys/linux/proc/mounts.ex` |
| `lib/hyper/sys/linux/subid.ex` | `lib/sys/linux/subid.ex` |

Call sites updated by the same global rename: `lib/hyper/node.ex`, `lib/hyper/node/fire_vmm/jailer.ex`, `lib/hyper/node/img/server.ex`, `lib/hyper/node/layer/server.ex`, `lib/hyper/node/users.ex`, `lib/hyper/vm/instance/spec.ex`, and the `groups_for_modules` block in `mix.exs`.

**New monitoring package:**

| File | Responsibility |
|------|----------------|
| `lib/controls/ewma.ex` | `Controls.Ewma` — pure first-order LPF (variable-`Δt` gain) |
| `lib/controls/rate.ex` | `Controls.Rate` — pure counter → bytes/sec, skipping resets & first sample |
| `lib/sys/mon/sampler.ex` | `Sys.Mon.Sampler` — behaviour every probe implements |
| `lib/sys/mon/server.ex` | `Sys.Mon.Server` — generic monitor GenServer (`Opts`, `Reading`, scheduling, telemetry) |
| `lib/sys/linux/proc/stat.ex` | `Sys.Linux.Proc.Stat` — parse `/proc/stat`, compute CPU utilization |
| `lib/sys/linux/proc/meminfo.ex` | `Sys.Linux.Proc.Meminfo` — parse `/proc/meminfo` |
| `lib/sys/linux/proc/diskstats.ex` | `Sys.Linux.Proc.Diskstats` — parse `/proc/diskstats`, sum physical-device bytes |
| `lib/sys/linux/proc/net_dev.ex` | `Sys.Linux.Proc.NetDev` — parse `/proc/net/dev`, sum non-loopback bytes |
| `lib/sys/mon/cpu.ex` | `Sys.Mon.Cpu` — CPU sampler + public `value/0` |
| `lib/sys/mon/mem.ex` | `Sys.Mon.Mem` — memory sampler + typed `Reading` |
| `lib/sys/mon/disk_bw.ex` | `Sys.Mon.DiskBw` — disk-bandwidth sampler + typed `Reading` |
| `lib/sys/mon/net_bw.ex` | `Sys.Mon.NetBw` — net-bandwidth sampler + typed `Reading` |
| `lib/sys/mon.ex` | `Sys.Mon` — supervisor + `readings/0` aggregate getter |
| `docs/cookbook/monitoring.md` | Narrative doc: soft metrics, the LPF, telemetry events |

Tests mirror under `test/sys/...`.

---

### Task 1: Migrate `Hyper.Sys.*` → top-level `Sys.*`

Pure move + rename. `Hyper.Sys` is an unambiguous prefix, so a global textual replace is safe. There are **no existing tests** under `test/` referencing `Hyper.Sys`, so nothing to port.

**Files:**
- Move (git): all nine files in the table above.
- Modify (by global rename): the moved files, plus `lib/hyper/node.ex`, `lib/hyper/node/fire_vmm/jailer.ex`, `lib/hyper/node/img/server.ex`, `lib/hyper/node/layer/server.ex`, `lib/hyper/node/users.ex`, `lib/hyper/vm/instance/spec.ex`, `mix.exs`.

**Interfaces:**
- Produces: modules `Sys.Posix`, `Sys.Linux.Cgroup`, `Sys.Linux.Cgroup.V2` (and nested `Sys.Linux.Cgroup.V2.Config`), `Sys.Linux.Dmsetup`, `Sys.Linux.Fstab`, `Sys.Linux.Losetup`, `Sys.Linux.Nss` (and nested `Passwd`/`Group`), `Sys.Linux.Proc.Mounts`, `Sys.Linux.Subid`. All public function signatures are unchanged — only the module prefix differs.

- [ ] **Step 1: Confirm the pre-migration build is green**

Run: `mix compile --warnings-as-errors --force`
Expected: compiles with no warnings (baseline before touching anything).

- [ ] **Step 2: Move the directory with git (preserves history)**

```bash
git mv lib/hyper/sys lib/sys
```

- [ ] **Step 3: Globally rename the module prefix across source + mix.exs**

```bash
grep -rl 'Hyper\.Sys' lib mix.exs | xargs sed -i 's/Hyper\.Sys/Sys/g'
```

This rewrites module definitions, `alias`es, fully-qualified call sites, the `@decorate with_span("Hyper.Sys...")` strings in `dmsetup.ex`/`losetup.ex`, and the `System:` group in `mix.exs`'s `groups_for_modules`.

- [ ] **Step 4: Verify no stragglers remain**

Run: `grep -rn 'Hyper\.Sys' lib test config mix.exs`
Expected: no output (exit code 1).

- [ ] **Step 5: Compile, format, lint, test**

Run:
```bash
mix compile --warnings-as-errors --force
mix format
mix format --check-formatted
mix credo --strict
mix test --warnings-as-errors
```
Expected: clean compile (no warnings), formatter makes no further changes, credo passes, all existing tests pass.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: extract Hyper.Sys into top-level Sys package under lib/sys"
```

---

### Task 2: `Controls.Ewma` — the low-pass filter core

The pure controls primitive. Variable-`Δt` gain, first-sample seeding. No process, no I/O — trivially testable.

**Files:**
- Create: `lib/controls/ewma.ex`
- Test: `test/controls/ewma_test.exs`

**Interfaces:**
- Produces:
  - `Controls.Ewma.t()` — opaque-ish struct `%Controls.Ewma{tau_ms: pos_integer(), value: float() | nil}`
  - `Controls.Ewma.new(tau_ms :: pos_integer()) :: t()`
  - `Controls.Ewma.update(t(), sample :: number(), dt_ms :: pos_integer()) :: t()`
  - `Controls.Ewma.value(t()) :: float() | nil`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Controls.EwmaTest do
  use ExUnit.Case, async: true

  alias Controls.Ewma

  test "value is nil before any sample" do
    assert Ewma.value(Ewma.new(1000)) == nil
  end

  test "seeds with the first sample (no warm-up ramp from zero)" do
    e = Ewma.new(1000) |> Ewma.update(0.5, 200)
    assert Ewma.value(e) == 0.5
  end

  test "with equal dt, tau chosen for alpha = 0.5 halves toward the new sample" do
    # 1 - exp(-dt/tau) = 0.5  =>  dt/tau = ln 2
    tau = round(1000 / :math.log(2))
    e = Ewma.new(tau) |> Ewma.update(0.0, 1000) |> Ewma.update(1.0, 1000)
    assert_in_delta Ewma.value(e), 0.5, 0.001
  end

  test "a sample after ~3 tau reaches ~95% of a unit step" do
    e = Ewma.new(1000) |> Ewma.update(0.0, 1000) |> Ewma.update(1.0, 3000)
    assert_in_delta Ewma.value(e), 0.95, 0.01
  end

  test "a sample much faster than tau barely moves the average" do
    e = Ewma.new(10_000) |> Ewma.update(0.0, 1) |> Ewma.update(1.0, 1)
    assert_in_delta Ewma.value(e), 0.0001, 0.00005
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/controls/ewma_test.exs`
Expected: FAIL — `Controls.Ewma.__struct__/1 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Controls.Ewma do
  @moduledoc """
  First-order exponential moving average — a discrete low-pass filter (LPF) with
  an irregular-sampling-correct gain.

  The continuous first-order LPF `τ·ẏ + y = x` has the exact discrete solution,
  for a step-held input over an interval `Δt`:

      α  = 1 − exp(−Δt/τ)
      yₙ = α·xₙ + (1−α)·yₙ₋₁

  Deriving `α` from the *measured* `Δt` (never a hardcoded constant) pins the
  filter's cutoff at `1/(2πτ)` regardless of scheduler jitter or differing
  per-monitor sample periods. `τ` (`tau_ms`) is the time constant: the output
  reaches ~63 % of a step after one `τ` and ~95 % after `3τ`. The first sample
  seeds the filter directly, avoiding a warm-up ramp from zero.
  """

  @enforce_keys [:tau_ms]
  defstruct [:tau_ms, value: nil]

  @type t :: %__MODULE__{tau_ms: pos_integer(), value: float() | nil}

  @doc "Build a filter with time constant `tau_ms` (milliseconds)."
  @spec new(pos_integer()) :: t()
  def new(tau_ms) when is_integer(tau_ms) and tau_ms > 0 do
    %__MODULE__{tau_ms: tau_ms}
  end

  @doc """
  Fold one `sample`, taken `dt_ms` after the previous one, into the filter.

  The first sample seeds the average (its `dt_ms` is ignored).
  """
  @spec update(t(), number(), pos_integer()) :: t()
  def update(%__MODULE__{value: nil} = e, sample, _dt_ms) do
    %{e | value: sample * 1.0}
  end

  def update(%__MODULE__{tau_ms: tau, value: prev} = e, sample, dt_ms)
      when is_integer(dt_ms) and dt_ms > 0 do
    alpha = 1.0 - :math.exp(-dt_ms / tau)
    %{e | value: alpha * sample + (1.0 - alpha) * prev}
  end

  @doc "The current filtered value, or `nil` before the first sample."
  @spec value(t()) :: float() | nil
  def value(%__MODULE__{value: v}), do: v
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/controls/ewma_test.exs`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/controls/ewma.ex test/controls/ewma_test.exs
git commit -m "feat(sys.mon): add Ewma low-pass filter with variable-dt gain"
```

---

### Task 3: `Controls.Rate` — counter → bytes/sec

Pure helper turning a monotonic byte counter into a per-second rate, skipping the first sample (no baseline) and counter resets (reboot).

**Files:**
- Create: `lib/controls/rate.ex`
- Test: `test/controls/rate_test.exs`

**Interfaces:**
- Produces:
  - `Controls.Rate.state() :: {count :: non_neg_integer(), mono_ms :: integer()} | nil`
  - `Controls.Rate.compute(state(), count :: non_neg_integer(), mono_ms :: integer()) :: {:ok, float(), state()} | {:skip, state()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Controls.RateTest do
  use ExUnit.Case, async: true

  alias Controls.Rate

  test "the first sample skips and stores the baseline" do
    assert {:skip, {100, 5}} = Rate.compute(nil, 100, 5)
  end

  test "computes bytes per second from a counter delta" do
    {:skip, st} = Rate.compute(nil, 1000, 0)
    assert {:ok, rate, {2000, 1000}} = Rate.compute(st, 2000, 1000)
    # 1000 bytes over 1000 ms = 1000 B/s
    assert_in_delta rate, 1000.0, 0.001
  end

  test "a counter reset (count < prev) skips instead of reporting negative" do
    assert {:skip, {10, 2000}} = Rate.compute({1000, 1000}, 10, 2000)
  end

  test "a non-positive dt skips" do
    assert {:skip, {200, 1000}} = Rate.compute({100, 1000}, 200, 1000)
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/controls/rate_test.exs`
Expected: FAIL — `Controls.Rate.compute/3 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Controls.Rate do
  @moduledoc """
  Turns a monotonically increasing byte counter (e.g. `/proc/diskstats` sectors
  or `/proc/net/dev` bytes) into a per-second rate.

  The first observation has no baseline, and a reboot resets the counter
  backwards; both cases return `:skip` (carrying the new baseline) rather than a
  meaningless or negative rate. `mono_ms` must come from `System.monotonic_time/1`.
  """

  @type state :: {non_neg_integer(), integer()} | nil

  @doc """
  Given the previous `state`, the latest cumulative `count`, and the monotonic
  timestamp `mono_ms` of this reading, return the rate in counter-units per
  second together with the new state.
  """
  @spec compute(state(), non_neg_integer(), integer()) ::
          {:ok, float(), state()} | {:skip, state()}
  def compute(nil, count, mono_ms), do: {:skip, {count, mono_ms}}

  def compute({prev_count, _prev_mono}, count, mono_ms) when count < prev_count do
    {:skip, {count, mono_ms}}
  end

  def compute({prev_count, prev_mono}, count, mono_ms) do
    dt = mono_ms - prev_mono

    if dt <= 0 do
      {:skip, {count, mono_ms}}
    else
      {:ok, (count - prev_count) * 1000.0 / dt, {count, mono_ms}}
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/controls/rate_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/controls/rate.ex test/controls/rate_test.exs
git commit -m "feat(sys.mon): add Rate helper (counter to bytes/sec)"
```

---

### Task 4: `Sys.Mon.Sampler` behaviour + `Sys.Mon.Server` generic monitor

The reusable engine. One GenServer drives any sampler: it self-schedules ticks, measures `Δt` with the monotonic clock, folds samples through `Ewma`, emits telemetry, and answers `value/0`. A test-only `sample_now/1` performs one synchronous sample so timing tests stay deterministic.

**Files:**
- Create: `lib/sys/mon/sampler.ex`
- Create: `lib/sys/mon/server.ex`
- Test: `test/sys/mon/server_test.exs`

**Interfaces:**
- Consumes: `Controls.Ewma` (Task 2), `Unit.Time` (existing — `Unit.Time.as_ms/1`, `Unit.Time.s/1`).
- Produces:
  - Behaviour `Sys.Mon.Sampler` with callbacks:
    - `init() :: {:ok, private :: term()} | {:error, term()}`
    - `sample(private :: term()) :: {:ok, reading :: float(), private :: term()} | {:skip, private :: term()} | {:error, term()}`
  - `Sys.Mon.Server.Opts.t()` — `%Sys.Mon.Server.Opts{sampler: module(), period: Unit.Time.t(), tau: Unit.Time.t(), name: GenServer.name(), telemetry_event: [atom()]}`
  - `Sys.Mon.Server.Reading.t()` — `%Sys.Mon.Server.Reading{instant: float() | nil, smoothed: float() | nil}`
  - `Sys.Mon.Server.start_link(Opts.t()) :: GenServer.on_start()`
  - `Sys.Mon.Server.value(GenServer.server()) :: Reading.t()`
  - `Sys.Mon.Server.sample_now(GenServer.server()) :: Reading.t()` (forces one sample; primarily for tests)
  - Telemetry: on every `:ok` sample, executes `telemetry_event` with measurements `%{instant: float(), smoothed: float()}` and empty metadata.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Mon.ServerTest do
  use ExUnit.Case, async: false

  alias Sys.Mon.Server
  alias Sys.Mon.Server.{Opts, Reading}
  alias Unit.Time

  # Fake sampler: replays a scripted queue of samples; :skip once drained.
  defmodule Queue do
    @behaviour Sys.Mon.Sampler

    @impl true
    def init, do: {:ok, [0.0, 1.0]}

    @impl true
    def sample([h | t]), do: {:ok, h, t}
    def sample([]), do: {:skip, []}
  end

  defp start(name, event) do
    opts = %Opts{
      sampler: Queue,
      # Huge period so the auto-tick never fires mid-test.
      period: Time.s(3600),
      tau: Time.s(1),
      name: name,
      telemetry_event: event
    }

    {:ok, pid} = Server.start_link(opts)
    pid
  end

  test "first sample seeds the filter; reading carries instant and smoothed" do
    start(:mon_seed, [:test, :seed])

    r0 = Server.sample_now(:mon_seed)
    assert %Reading{instant: 0.0, smoothed: 0.0} = r0
  end

  test "second sample (tiny dt) barely moves the smoothed value" do
    start(:mon_step, [:test, :step])

    _ = Server.sample_now(:mon_step)
    r1 = Server.sample_now(:mon_step)

    assert r1.instant == 1.0
    assert_in_delta r1.smoothed, 0.0, 0.01
  end

  test "value/0 reports the latest reading without sampling" do
    start(:mon_value, [:test, :value])

    _ = Server.sample_now(:mon_value)
    assert %Reading{instant: 0.0} = Server.value(:mon_value)
  end

  test "emits a telemetry event per :ok sample" do
    ref = make_ref()

    :telemetry.attach(
      "test-#{inspect(ref)}",
      [:test, :emit],
      fn event, meas, _meta, pid -> send(pid, {:telemetry, event, meas}) end,
      self()
    )

    start(:mon_emit, [:test, :emit])
    _ = Server.sample_now(:mon_emit)

    assert_receive {:telemetry, [:test, :emit], %{instant: 0.0, smoothed: 0.0}}
    :telemetry.detach("test-#{inspect(ref)}")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/mon/server_test.exs`
Expected: FAIL — `Sys.Mon.Server.Opts.__struct__/1 is undefined`.

- [ ] **Step 3: Write the behaviour**

```elixir
defmodule Sys.Mon.Sampler do
  @moduledoc """
  Behaviour for a single soft-metric probe.

  A sampler is the I/O-bearing source of instantaneous readings driven by
  `Sys.Mon.Server`. It may carry private state between samples (e.g. the previous
  `/proc/stat` snapshot needed to turn cumulative counters into a rate). All
  readings are plain floats in the sampler's natural unit (a fraction for CPU,
  bytes for memory, bytes/sec for bandwidth); the owning monitor re-applies a
  domain `Unit.*` at its public boundary.
  """

  @typedoc "Sampler-private carry-over state."
  @type private :: term()

  @typedoc "An instantaneous reading in the sampler's natural unit."
  @type reading :: float()

  @doc "Initialize sampler-private state."
  @callback init() :: {:ok, private()} | {:error, term()}

  @doc """
  Produce the next reading.

  `:skip` means a reading could not yet be formed (e.g. no baseline for a rate),
  and the filter is left untouched. `:error` is a transient failure to be logged.
  """
  @callback sample(private()) ::
              {:ok, reading(), private()} | {:skip, private()} | {:error, term()}
end
```

- [ ] **Step 4: Write the server**

```elixir
defmodule Sys.Mon.Server do
  @moduledoc """
  Generic monitor process: drives a `Sys.Mon.Sampler` on a fixed period, folds
  each reading through a `Controls.Ewma` low-pass filter, emits a `:telemetry`
  event, and answers `value/0`.

  Ticks self-schedule with `Process.send_after` *after* each sample completes, so
  a slow sample cannot let ticks pile up. `Δt` for the filter is measured with
  `System.monotonic_time/1`, so the EWMA gain stays correct under jitter.
  """

  use GenServer
  require Logger

  alias Controls.Ewma

  defmodule Reading do
    @moduledoc "A monitor reading: the latest instantaneous and filtered values (raw floats)."
    @type t :: %__MODULE__{instant: float() | nil, smoothed: float() | nil}
    defstruct [:instant, :smoothed]
  end

  defmodule Opts do
    @moduledoc "Start options for a `Sys.Mon.Server`."
    @type t :: %__MODULE__{
            sampler: module(),
            period: Unit.Time.t(),
            tau: Unit.Time.t(),
            name: GenServer.name(),
            telemetry_event: [atom()]
          }
    @enforce_keys [:sampler, :period, :tau, :name, :telemetry_event]
    defstruct [:sampler, :period, :tau, :name, :telemetry_event]
  end

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            sampler: module(),
            sampler_state: term(),
            period_ms: pos_integer(),
            ewma: Ewma.t(),
            last_mono: integer() | nil,
            instant: float() | nil,
            telemetry_event: [atom()]
          }
    @enforce_keys [:sampler, :sampler_state, :period_ms, :ewma, :telemetry_event]
    defstruct [
      :sampler,
      :sampler_state,
      :period_ms,
      :ewma,
      :last_mono,
      :instant,
      :telemetry_event
    ]
  end

  @doc "Start a monitor for the sampler described by `opts`."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{name: name} = opts) do
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The latest instantaneous + filtered reading."
  @spec value(GenServer.server()) :: Reading.t()
  def value(server), do: GenServer.call(server, :value)

  @doc "Force a single synchronous sample and return the resulting reading. Mainly for tests."
  @spec sample_now(GenServer.server()) :: Reading.t()
  def sample_now(server), do: GenServer.call(server, :sample_now)

  @impl true
  def init(%Opts{} = opts) do
    case opts.sampler.init() do
      {:ok, sampler_state} ->
        period_ms = Unit.Time.as_ms(opts.period)
        _ = Process.send_after(self(), :tick, period_ms)

        {:ok,
         %State{
           sampler: opts.sampler,
           sampler_state: sampler_state,
           period_ms: period_ms,
           ewma: Ewma.new(Unit.Time.as_ms(opts.tau)),
           last_mono: nil,
           instant: nil,
           telemetry_event: opts.telemetry_event
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:value, _from, state), do: {:reply, reading(state), state}

  @impl true
  def handle_call(:sample_now, _from, state) do
    state = do_sample(state)
    {:reply, reading(state), state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_sample(state)
    _ = Process.send_after(self(), :tick, state.period_ms)
    {:noreply, state}
  end

  # Take one reading from the sampler and fold it into the filter.
  @spec do_sample(State.t()) :: State.t()
  defp do_sample(state) do
    now = System.monotonic_time(:millisecond)

    case state.sampler.sample(state.sampler_state) do
      {:ok, x, sampler_state} ->
        dt = if state.last_mono, do: max(now - state.last_mono, 1), else: state.period_ms
        ewma = Ewma.update(state.ewma, x, dt)
        :telemetry.execute(state.telemetry_event, %{instant: x, smoothed: Ewma.value(ewma)}, %{})
        %{state | sampler_state: sampler_state, ewma: ewma, instant: x, last_mono: now}

      {:skip, sampler_state} ->
        %{state | sampler_state: sampler_state, last_mono: now}

      {:error, reason} ->
        Logger.warning("#{inspect(state.sampler)} sample failed: #{inspect(reason)}")
        state
    end
  end

  @spec reading(State.t()) :: Reading.t()
  defp reading(state) do
    %Reading{instant: state.instant, smoothed: Ewma.value(state.ewma)}
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `mix test test/sys/mon/server_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/sys/mon/sampler.ex lib/sys/mon/server.ex test/sys/mon/server_test.exs
git commit -m "feat(sys.mon): add Sampler behaviour and generic monitor Server"
```

---

### Task 5: `Sys.Linux.Proc.Stat` — `/proc/stat` parser + CPU utilization

**Files:**
- Create: `lib/sys/linux/proc/stat.ex`
- Test: `test/sys/linux/proc/stat_test.exs`

**Interfaces:**
- Produces:
  - `Sys.Linux.Proc.Stat.Snapshot.t()` — `%Sys.Linux.Proc.Stat.Snapshot{idle: non_neg_integer(), total: non_neg_integer()}`
  - `Sys.Linux.Proc.Stat.parse(String.t()) :: Snapshot.t()`
  - `Sys.Linux.Proc.Stat.read() :: {:ok, Snapshot.t()} | {:error, File.posix()}`
  - `Sys.Linux.Proc.Stat.utilization(prev :: Snapshot.t(), curr :: Snapshot.t()) :: float()` (busy fraction, clamped to `0.0..1.0`)

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Linux.Proc.StatTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.Stat
  alias Sys.Linux.Proc.Stat.Snapshot

  @sample """
  cpu  100 0 50 1000 50 0 0 0 0 0
  cpu0 50 0 25 500 25 0 0 0 0 0
  intr 12345 0 0
  ctxt 67890
  """

  test "parses the aggregate cpu line into idle (idle+iowait) and total jiffies" do
    # idle = 1000 + 50 = 1050 ; total = 100+0+50+1000+50 = 1200
    assert %Snapshot{idle: 1050, total: 1200} = Stat.parse(@sample)
  end

  test "utilization is the busy fraction between two snapshots" do
    s0 = %Snapshot{idle: 1000, total: 2000}
    # dt = 400, di = 100, busy = 300 => 0.75
    s1 = %Snapshot{idle: 1100, total: 2400}
    assert Stat.utilization(s0, s1) == 0.75
  end

  test "utilization clamps and tolerates a zero-length interval" do
    s = %Snapshot{idle: 100, total: 200}
    assert Stat.utilization(s, s) == 0.0
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/linux/proc/stat_test.exs`
Expected: FAIL — `Sys.Linux.Proc.Stat.parse/1 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Linux.Proc.Stat do
  @moduledoc """
  Reads aggregate CPU time counters from `/proc/stat`.

  The first line (`cpu  …`) holds cumulative jiffies since boot across all cores:
  `user nice system idle iowait irq softirq steal guest guest_nice`. A single read
  is meaningless on its own — CPU *utilization* is the busy fraction between two
  snapshots (see `utilization/2`). `idle` here folds in `iowait`, the conventional
  "not doing work" bucket.
  """

  @path "/proc/stat"

  defmodule Snapshot do
    @moduledoc "Cumulative idle and total CPU jiffies at one instant."
    @type t :: %__MODULE__{idle: non_neg_integer(), total: non_neg_integer()}
    @enforce_keys [:idle, :total]
    defstruct [:idle, :total]
  end

  @doc "Read and parse `/proc/stat`."
  @spec read() :: {:ok, Snapshot.t()} | {:error, File.posix()}
  def read do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc "Parse the aggregate `cpu` line of a `/proc/stat` payload."
  @spec parse(String.t()) :: Snapshot.t()
  def parse(content) do
    ["cpu" | fields] =
      content
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.split()

    nums = Enum.map(fields, &String.to_integer/1)
    [_user, _nice, _system, idle, iowait | _rest] = nums

    %Snapshot{idle: idle + iowait, total: Enum.sum(nums)}
  end

  @doc """
  CPU utilization (busy fraction, `0.0..1.0`) between an earlier and a later
  snapshot. A non-positive interval yields `0.0`.
  """
  @spec utilization(Snapshot.t(), Snapshot.t()) :: float()
  def utilization(%Snapshot{idle: i0, total: t0}, %Snapshot{idle: i1, total: t1}) do
    dt = t1 - t0
    di = i1 - i0

    if dt <= 0 do
      0.0
    else
      (dt - di) / dt
      |> max(0.0)
      |> min(1.0)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/linux/proc/stat_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/linux/proc/stat.ex test/sys/linux/proc/stat_test.exs
git commit -m "feat(sys): add /proc/stat parser and CPU utilization"
```

---

### Task 6: `Sys.Linux.Proc.Meminfo` — `/proc/meminfo` parser

**Files:**
- Create: `lib/sys/linux/proc/meminfo.ex`
- Test: `test/sys/linux/proc/meminfo_test.exs`

**Interfaces:**
- Consumes: `Unit.Information` (existing — `Unit.Information.kib/1`, `Unit.Information.as_bytes/1`).
- Produces:
  - `Sys.Linux.Proc.Meminfo.Snapshot.t()` — `%Sys.Linux.Proc.Meminfo.Snapshot{total: Unit.Information.t(), available: Unit.Information.t()}`
  - `Sys.Linux.Proc.Meminfo.parse(String.t()) :: Snapshot.t()`
  - `Sys.Linux.Proc.Meminfo.read() :: {:ok, Snapshot.t()} | {:error, File.posix()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Linux.Proc.MeminfoTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.Meminfo
  alias Sys.Linux.Proc.Meminfo.Snapshot
  alias Unit.Information

  @sample """
  MemTotal:       16384 kB
  MemFree:         1024 kB
  MemAvailable:    8192 kB
  Buffers:            0 kB
  """

  test "parses MemTotal and MemAvailable as Information" do
    assert %Snapshot{total: total, available: avail} = Meminfo.parse(@sample)
    assert Information.as_bytes(total) == 16_384 * 1024
    assert Information.as_bytes(avail) == 8_192 * 1024
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/linux/proc/meminfo_test.exs`
Expected: FAIL — `Sys.Linux.Proc.Meminfo.parse/1 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Linux.Proc.Meminfo do
  @moduledoc """
  Reads memory totals from `/proc/meminfo`.

  `MemAvailable` is the kernel's own estimate of memory obtainable for a new
  workload without swapping — the right figure for "how loaded is this node",
  preferable to `MemFree` (which ignores reclaimable cache). Values in the file
  are kibibytes; they are returned as `Unit.Information`.
  """

  alias Unit.Information

  @path "/proc/meminfo"

  defmodule Snapshot do
    @moduledoc "Total and kernel-available memory at one instant."
    @type t :: %__MODULE__{total: Information.t(), available: Information.t()}
    @enforce_keys [:total, :available]
    defstruct [:total, :available]
  end

  @doc "Read and parse `/proc/meminfo`."
  @spec read() :: {:ok, Snapshot.t()} | {:error, File.posix()}
  def read do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc "Parse a `/proc/meminfo` payload."
  @spec parse(String.t()) :: Snapshot.t()
  def parse(content) do
    kib = field_map(content)

    %Snapshot{
      total: Information.kib(Map.fetch!(kib, "MemTotal")),
      available: Information.kib(Map.fetch!(kib, "MemAvailable"))
    }
  end

  # Build %{"MemTotal" => 16384, ...} from "Key: <n> kB" lines.
  @spec field_map(String.t()) :: %{String.t() => non_neg_integer()}
  defp field_map(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [key, value | _rest] -> [{String.trim_trailing(key, ":"), String.to_integer(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/linux/proc/meminfo_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/linux/proc/meminfo.ex test/sys/linux/proc/meminfo_test.exs
git commit -m "feat(sys): add /proc/meminfo parser"
```

---

### Task 7: `Sys.Linux.Proc.Diskstats` — `/proc/diskstats` parser

Sums read+write bytes across **whole physical disks only** (whole-disk counters already include their partitions, so counting partitions too would double-count; virtual devices like `loop`/`dm-`/`ram` are excluded).

**Files:**
- Create: `lib/sys/linux/proc/diskstats.ex`
- Test: `test/sys/linux/proc/diskstats_test.exs`

**Interfaces:**
- Produces:
  - `Sys.Linux.Proc.Diskstats.parse(String.t()) :: %{String.t() => non_neg_integer()}` (device name → cumulative bytes)
  - `Sys.Linux.Proc.Diskstats.physical_device?(String.t()) :: boolean()`
  - `Sys.Linux.Proc.Diskstats.total_physical(String.t()) :: non_neg_integer()` (bytes across whole physical disks)
  - `Sys.Linux.Proc.Diskstats.read_total_physical() :: {:ok, non_neg_integer()} | {:error, File.posix()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Linux.Proc.DiskstatsTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.Diskstats

  # Columns: major minor name reads_completed reads_merged sectors_read ms_reading
  #          writes_completed writes_merged sectors_written ...
  @sample """
   259       0 nvme0n1 1000 0 4000 0 500 0 8000 0 0 0 0
   259       1 nvme0n1p1 10 0 40 0 5 0 80 0 0 0 0
     7       0 loop0 0 0 0 0 0 0 0 0 0 0 0
     8       0 sda 100 0 200 0 50 0 600 0 0 0 0
     8       1 sda1 1 0 2 0 1 0 4 0 0 0 0
  """

  test "parse computes (sectors_read + sectors_written) * 512 per device" do
    parsed = Diskstats.parse(@sample)
    # nvme0n1: (4000 + 8000) * 512
    assert parsed["nvme0n1"] == 12_000 * 512
    # sda: (200 + 600) * 512
    assert parsed["sda"] == 800 * 512
  end

  test "physical_device? accepts whole disks and rejects partitions and virtual devices" do
    assert Diskstats.physical_device?("nvme0n1")
    assert Diskstats.physical_device?("sda")
    refute Diskstats.physical_device?("nvme0n1p1")
    refute Diskstats.physical_device?("sda1")
    refute Diskstats.physical_device?("loop0")
    refute Diskstats.physical_device?("dm-0")
  end

  test "total_physical sums only whole physical disks" do
    # nvme0n1 (12000*512) + sda (800*512)
    assert Diskstats.total_physical(@sample) == (12_000 + 800) * 512
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/linux/proc/diskstats_test.exs`
Expected: FAIL — `Sys.Linux.Proc.Diskstats.parse/1 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Linux.Proc.Diskstats do
  @moduledoc """
  Reads cumulative block-device I/O from `/proc/diskstats`.

  Per line the fields after `major minor name` are `reads_completed reads_merged
  sectors_read … writes_completed writes_merged sectors_written …`. A sector is
  512 bytes. Whole-disk counters already include their partitions' I/O, so
  `total_physical/1` counts whole physical disks only — summing partitions too
  would double-count, and virtual devices (`loop`, `dm-`, `ram`, `md`, …) are not
  real node bandwidth.
  """

  @path "/proc/diskstats"
  @sector_bytes 512

  # sectors_read and sectors_written, 0-based among whitespace-split tokens.
  @sectors_read_idx 5
  @sectors_written_idx 9

  @virtual_prefix ~r/^(loop|ram|zram|sr|fd|md|dm-)/
  @nvme_mmc_partition ~r/^(nvme\d+n\d+|mmcblk\d+)p\d+$/
  @scsi_partition ~r/^(sd|vd|hd|xvd)[a-z]+\d+$/

  @doc "Read `/proc/diskstats` and total the bytes across whole physical disks."
  @spec read_total_physical() :: {:ok, non_neg_integer()} | {:error, File.posix()}
  def read_total_physical do
    with {:ok, content} <- File.read(@path), do: {:ok, total_physical(content)}
  end

  @doc "Map each device name to its cumulative (read + written) bytes."
  @spec parse(String.t()) :: %{String.t() => non_neg_integer()}
  def parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_major, _minor, name | _rest] = fields when length(fields) > @sectors_written_idx ->
          read = String.to_integer(Enum.at(fields, @sectors_read_idx))
          written = String.to_integer(Enum.at(fields, @sectors_written_idx))
          [{name, (read + written) * @sector_bytes}]

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  @doc "Whether `name` is a whole physical disk (not a partition or virtual device)."
  @spec physical_device?(String.t()) :: boolean()
  def physical_device?(name) do
    not Regex.match?(@virtual_prefix, name) and
      not Regex.match?(@nvme_mmc_partition, name) and
      not Regex.match?(@scsi_partition, name)
  end

  @doc "Total cumulative bytes across whole physical disks."
  @spec total_physical(String.t()) :: non_neg_integer()
  def total_physical(content) do
    content
    |> parse()
    |> Enum.filter(fn {name, _bytes} -> physical_device?(name) end)
    |> Enum.map(fn {_name, bytes} -> bytes end)
    |> Enum.sum()
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/linux/proc/diskstats_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/linux/proc/diskstats.ex test/sys/linux/proc/diskstats_test.exs
git commit -m "feat(sys): add /proc/diskstats parser (physical-device bytes)"
```

---

### Task 8: `Sys.Linux.Proc.NetDev` — `/proc/net/dev` parser

Sums rx+tx bytes across non-loopback interfaces.

**Files:**
- Create: `lib/sys/linux/proc/net_dev.ex`
- Test: `test/sys/linux/proc/net_dev_test.exs`

**Interfaces:**
- Produces:
  - `Sys.Linux.Proc.NetDev.parse(String.t()) :: %{String.t() => non_neg_integer()}` (interface → cumulative rx+tx bytes)
  - `Sys.Linux.Proc.NetDev.total(String.t()) :: non_neg_integer()` (bytes across all interfaces except `lo`)
  - `Sys.Linux.Proc.NetDev.read_total() :: {:ok, non_neg_integer()} | {:error, File.posix()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Linux.Proc.NetDevTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.NetDev

  @sample """
  Inter-|   Receive                                                |  Transmit
   face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
      lo: 1000      10    0    0    0     0          0         0     2000      20    0    0    0     0       0          0
    eth0: 5000      50    0    0    0     0          0         0     7000      70    0    0    0     0       0          0
  """

  test "parse sums rx + tx bytes per interface" do
    parsed = NetDev.parse(@sample)
    assert parsed["lo"] == 1000 + 2000
    assert parsed["eth0"] == 5000 + 7000
  end

  test "total excludes the loopback interface" do
    assert NetDev.total(@sample) == 5000 + 7000
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/linux/proc/net_dev_test.exs`
Expected: FAIL — `Sys.Linux.Proc.NetDev.parse/1 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Linux.Proc.NetDev do
  @moduledoc """
  Reads cumulative per-interface traffic from `/proc/net/dev`.

  Each data line is `iface: <rx fields…> <tx fields…>` where the first receive
  field is `bytes` and the ninth field overall (the first transmit field) is also
  `bytes`. `total/1` sums rx+tx across every interface except loopback (`lo`),
  which is not real node bandwidth.
  """

  @path "/proc/net/dev"

  # Within the post-colon fields (0-based): rx bytes, then 8 rx fields, then tx bytes.
  @rx_bytes_idx 0
  @tx_bytes_idx 8

  @doc "Read `/proc/net/dev` and total non-loopback bytes."
  @spec read_total() :: {:ok, non_neg_integer()} | {:error, File.posix()}
  def read_total do
    with {:ok, content} <- File.read(@path), do: {:ok, total(content)}
  end

  @doc "Map each interface to its cumulative (rx + tx) bytes."
  @spec parse(String.t()) :: %{String.t() => non_neg_integer()}
  def parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [left, right] ->
          fields = String.split(right)

          if length(fields) > @tx_bytes_idx do
            rx = String.to_integer(Enum.at(fields, @rx_bytes_idx))
            tx = String.to_integer(Enum.at(fields, @tx_bytes_idx))
            [{String.trim(left), rx + tx}]
          else
            []
          end

        _ ->
          []
      end
    end)
    |> Map.new()
  end

  @doc "Total cumulative bytes across all interfaces except loopback."
  @spec total(String.t()) :: non_neg_integer()
  def total(content) do
    content
    |> parse()
    |> Enum.reject(fn {iface, _bytes} -> iface == "lo" end)
    |> Enum.map(fn {_iface, bytes} -> bytes end)
    |> Enum.sum()
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/linux/proc/net_dev_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/linux/proc/net_dev.ex test/sys/linux/proc/net_dev_test.exs
git commit -m "feat(sys): add /proc/net/dev parser"
```

---

### Task 9: `Sys.Mon.Cpu` — CPU monitor

A `Sampler` over `/proc/stat` deltas (skips the first sample — no baseline) plus the public API. CPU readings are dimensionless fractions `0.0..1.0`, so `Cpu.value/0` returns `Sys.Mon.Server.Reading` directly.

**Files:**
- Create: `lib/sys/mon/cpu.ex`
- Test: `test/sys/mon/cpu_test.exs`

**Interfaces:**
- Consumes: `Sys.Linux.Proc.Stat` (Task 5), `Sys.Mon.Server` (Task 4), `Unit.Time`.
- Produces:
  - `Sys.Mon.Cpu` implements `Sys.Mon.Sampler` (`init/0`, `sample/1`).
  - `Sys.Mon.Cpu.child_spec(term()) :: Supervisor.child_spec()` (starts a `Server` named `Sys.Mon.Cpu`).
  - `Sys.Mon.Cpu.value() :: Sys.Mon.Server.Reading.t()` (fields are fractions `0.0..1.0`).
  - Period `2 s`, time constant `30 s`, telemetry event `[:sys, :mon, :cpu]`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Mon.CpuTest do
  use ExUnit.Case, async: true

  alias Sys.Mon.Cpu

  test "init carries no baseline snapshot" do
    assert {:ok, nil} = Cpu.init()
  end

  test "the first sample skips (establishes a baseline), the second reports a fraction" do
    {:ok, nil} = Cpu.init()
    # We cannot stub File here, so drive the two-phase contract directly:
    # the sampler must :skip when its private state is nil-derived first read.
    assert {:skip, snap1} = Cpu.sample(nil)
    assert match?({tag, _value, _snap2} when tag in [:ok], Cpu.sample(snap1)) or
             match?({:skip, _}, Cpu.sample(snap1))
  end

  test "exposes a 2-second period and 30-second time constant via child_spec" do
    spec = Cpu.child_spec([])
    assert spec.id == Sys.Mon.Cpu
    assert {Sys.Mon.Server, :start_link, [opts]} = spec.start
    assert Unit.Time.as_s(opts.period) == 2
    assert Unit.Time.as_s(opts.tau) == 30
    assert opts.telemetry_event == [:sys, :mon, :cpu]
  end
end
```

> Note: `sample/1`'s first call reads the real `/proc/stat`, returns `{:skip, snapshot}`, and the second call returns `{:ok, fraction, snapshot}` (or `{:skip, …}` if the two reads were too close to differ). The test asserts the contract shape, not an exact load.

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/mon/cpu_test.exs`
Expected: FAIL — `Sys.Mon.Cpu.init/0 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Mon.Cpu do
  @moduledoc """
  Monitors instantaneous CPU utilization (the soft β_vcpus signal).

  Samples `/proc/stat` every #{2} seconds and reports the busy fraction
  (`0.0..1.0`, normalized across all cores) between consecutive reads — never the
  load average, which has different semantics. The first read only establishes a
  baseline (`:skip`). Readings are smoothed with a 30-second time constant.

  Telemetry: `[:sys, :mon, :cpu]` with measurements `%{instant: float, smoothed: float}`.
  """

  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Stat
  alias Sys.Mon.Server
  alias Unit.Time

  @period Time.s(2)
  @tau Time.s(30)
  @event [:sys, :mon, :cpu]

  @doc "The latest instantaneous + filtered CPU utilization (fractions `0.0..1.0`)."
  @spec value() :: Server.Reading.t()
  def value, do: Server.value(__MODULE__)

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    opts = %Server.Opts{
      sampler: __MODULE__,
      period: @period,
      tau: @tau,
      name: __MODULE__,
      telemetry_event: @event
    }

    %{id: __MODULE__, start: {Server, :start_link, [opts]}}
  end

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(prev_snapshot) do
    case Stat.read() do
      {:ok, snapshot} ->
        case prev_snapshot do
          nil -> {:skip, snapshot}
          prev -> {:ok, Stat.utilization(prev, snapshot), snapshot}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/mon/cpu_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/mon/cpu.ex test/sys/mon/cpu_test.exs
git commit -m "feat(sys.mon): add Cpu monitor (/proc/stat utilization)"
```

---

### Task 10: `Sys.Mon.Mem` — memory monitor

Memory used is instantaneous (no baseline needed). `Mem.value/0` wraps the filtered float (bytes) back into `Unit.Information`.

**Files:**
- Create: `lib/sys/mon/mem.ex`
- Test: `test/sys/mon/mem_test.exs`

**Interfaces:**
- Consumes: `Sys.Linux.Proc.Meminfo` (Task 6), `Sys.Mon.Server` (Task 4), `Unit.Information`, `Unit.Time`.
- Produces:
  - `Sys.Mon.Mem` implements `Sys.Mon.Sampler`.
  - `Sys.Mon.Mem.Reading.t()` — `%Sys.Mon.Mem.Reading{instant: Unit.Information.t() | nil, smoothed: Unit.Information.t() | nil}`
  - `Sys.Mon.Mem.child_spec(term()) :: Supervisor.child_spec()` (starts a `Server` named `Sys.Mon.Mem`).
  - `Sys.Mon.Mem.value() :: Reading.t()`
  - Period `5 s`, time constant `30 s`, telemetry event `[:sys, :mon, :mem]`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Mon.MemTest do
  use ExUnit.Case, async: true

  alias Sys.Mon.Mem
  alias Unit.Information

  test "sample reports used bytes (total - available) as a float" do
    # init holds no state; sample reads the live /proc/meminfo.
    assert {:ok, nil} = Mem.init()
    assert {:ok, used, nil} = Mem.sample(nil)
    assert is_float(used)
    assert used >= 0.0
  end

  test "value wraps the filtered float back into Unit.Information" do
    # Drive Server through Mem's child_spec, force a sample, and check the wrap.
    spec = Mem.child_spec([])
    assert {Sys.Mon.Server, :start_link, [opts]} = spec.start
    {:ok, _pid} = Sys.Mon.Server.start_link(opts)

    _ = Sys.Mon.Server.sample_now(Sys.Mon.Mem)
    reading = Mem.value()

    assert %Mem.Reading{instant: %Information{}} = reading
  end

  test "child_spec uses a 5s period and 30s time constant" do
    spec = Mem.child_spec([])
    {Sys.Mon.Server, :start_link, [opts]} = spec.start
    assert Unit.Time.as_s(opts.period) == 5
    assert Unit.Time.as_s(opts.tau) == 30
    assert opts.telemetry_event == [:sys, :mon, :mem]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/mon/mem_test.exs`
Expected: FAIL — `Sys.Mon.Mem.init/0 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Mon.Mem do
  @moduledoc """
  Monitors instantaneous memory pressure.

  Samples `/proc/meminfo` every 5 seconds and reports *used* memory as
  `MemTotal − MemAvailable`, smoothed with a 30-second time constant. Although
  memory is an α (hard) budget tracked from VM specs, the live figure is useful
  for detecting actual pressure. Readings are `Unit.Information`.

  Telemetry: `[:sys, :mon, :mem]` with measurements `%{instant: float, smoothed: float}` (bytes).
  """

  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Meminfo
  alias Sys.Mon.Server
  alias Unit.Information
  alias Unit.Time

  @period Time.s(5)
  @tau Time.s(30)
  @event [:sys, :mon, :mem]

  defmodule Reading do
    @moduledoc "Instantaneous and filtered used-memory readings."
    @type t :: %__MODULE__{instant: Information.t() | nil, smoothed: Information.t() | nil}
    defstruct [:instant, :smoothed]
  end

  @doc "The latest instantaneous + filtered used memory."
  @spec value() :: Reading.t()
  def value do
    %Server.Reading{instant: instant, smoothed: smoothed} = Server.value(__MODULE__)
    %Reading{instant: to_info(instant), smoothed: to_info(smoothed)}
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    opts = %Server.Opts{
      sampler: __MODULE__,
      period: @period,
      tau: @tau,
      name: __MODULE__,
      telemetry_event: @event
    }

    %{id: __MODULE__, start: {Server, :start_link, [opts]}}
  end

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(_state) do
    case Meminfo.read() do
      {:ok, %Meminfo.Snapshot{total: total, available: available}} ->
        used = Information.as_bytes(total) - Information.as_bytes(available)
        {:ok, used * 1.0, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_info(float() | nil) :: Information.t() | nil
  defp to_info(nil), do: nil
  defp to_info(bytes), do: Information.bytes(round(bytes))
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/mon/mem_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/mon/mem.ex test/sys/mon/mem_test.exs
git commit -m "feat(sys.mon): add Mem monitor (/proc/meminfo used bytes)"
```

---

### Task 11: `Sys.Mon.DiskBw` — disk-bandwidth monitor

A rate sampler over `/proc/diskstats`. Private state is a `Controls.Rate` state holding the previous byte count and monotonic timestamp. `value/0` wraps the filtered float (bytes/sec) into `Unit.Bandwidth`.

**Files:**
- Create: `lib/sys/mon/disk_bw.ex`
- Test: `test/sys/mon/disk_bw_test.exs`

**Interfaces:**
- Consumes: `Sys.Linux.Proc.Diskstats` (Task 7), `Controls.Rate` (Task 3), `Sys.Mon.Server` (Task 4), `Unit.Bandwidth`, `Unit.Time`.
- Produces:
  - `Sys.Mon.DiskBw` implements `Sys.Mon.Sampler`.
  - `Sys.Mon.DiskBw.Reading.t()` — `%Sys.Mon.DiskBw.Reading{instant: Unit.Bandwidth.t() | nil, smoothed: Unit.Bandwidth.t() | nil}`
  - `Sys.Mon.DiskBw.child_spec(term()) :: Supervisor.child_spec()` (starts a `Server` named `Sys.Mon.DiskBw`).
  - `Sys.Mon.DiskBw.value() :: Reading.t()`
  - Period `7 s`, time constant `20 s`, telemetry event `[:sys, :mon, :disk_bw]`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Mon.DiskBwTest do
  use ExUnit.Case, async: true

  alias Sys.Mon.DiskBw
  alias Unit.Bandwidth

  test "init starts with no Rate baseline" do
    assert {:ok, nil} = DiskBw.init()
  end

  test "the first sample skips (establishes a baseline)" do
    assert {:skip, {_count, _mono}} = DiskBw.sample(nil)
  end

  test "value wraps the filtered float into Unit.Bandwidth" do
    spec = DiskBw.child_spec([])
    {Sys.Mon.Server, :start_link, [opts]} = spec.start
    {:ok, _pid} = Sys.Mon.Server.start_link(opts)

    # First sample only sets a baseline (:skip), so smoothed stays nil.
    _ = Sys.Mon.Server.sample_now(Sys.Mon.DiskBw)
    assert %DiskBw.Reading{instant: nil, smoothed: nil} = DiskBw.value()
  end

  test "child_spec uses a 7s period and 20s time constant" do
    spec = DiskBw.child_spec([])
    {Sys.Mon.Server, :start_link, [opts]} = spec.start
    assert Unit.Time.as_s(opts.period) == 7
    assert Unit.Time.as_s(opts.tau) == 20
    assert opts.telemetry_event == [:sys, :mon, :disk_bw]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/mon/disk_bw_test.exs`
Expected: FAIL — `Sys.Mon.DiskBw.init/0 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Mon.DiskBw do
  @moduledoc """
  Monitors instantaneous disk bandwidth (the soft β_disk_bw signal).

  Samples cumulative read+write bytes across whole physical disks from
  `/proc/diskstats` every 7 seconds and differentiates them into bytes/sec via
  `Controls.Rate` (the first read only establishes a baseline). The rate series is
  smoothed with a 20-second time constant. Readings are `Unit.Bandwidth`.

  Telemetry: `[:sys, :mon, :disk_bw]` with measurements `%{instant: float, smoothed: float}` (bytes/sec).
  """

  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Diskstats
  alias Controls.Rate
  alias Sys.Mon.Server
  alias Unit.Bandwidth
  alias Unit.Time

  @period Time.s(7)
  @tau Time.s(20)
  @event [:sys, :mon, :disk_bw]

  defmodule Reading do
    @moduledoc "Instantaneous and filtered disk-bandwidth readings."
    @type t :: %__MODULE__{instant: Bandwidth.t() | nil, smoothed: Bandwidth.t() | nil}
    defstruct [:instant, :smoothed]
  end

  @doc "The latest instantaneous + filtered disk bandwidth."
  @spec value() :: Reading.t()
  def value do
    %Server.Reading{instant: instant, smoothed: smoothed} = Server.value(__MODULE__)
    %Reading{instant: to_bw(instant), smoothed: to_bw(smoothed)}
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    opts = %Server.Opts{
      sampler: __MODULE__,
      period: @period,
      tau: @tau,
      name: __MODULE__,
      telemetry_event: @event
    }

    %{id: __MODULE__, start: {Server, :start_link, [opts]}}
  end

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(rate_state) do
    case Diskstats.read_total_physical() do
      {:ok, bytes} ->
        Rate.compute(rate_state, bytes, System.monotonic_time(:millisecond))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_bw(float() | nil) :: Bandwidth.t() | nil
  defp to_bw(nil), do: nil
  defp to_bw(bytes_per_sec), do: Bandwidth.bps(round(bytes_per_sec))
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/mon/disk_bw_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/mon/disk_bw.ex test/sys/mon/disk_bw_test.exs
git commit -m "feat(sys.mon): add DiskBw monitor (/proc/diskstats rate)"
```

---

### Task 12: `Sys.Mon.NetBw` — net-bandwidth monitor

Identical shape to `DiskBw`, over `/proc/net/dev`.

**Files:**
- Create: `lib/sys/mon/net_bw.ex`
- Test: `test/sys/mon/net_bw_test.exs`

**Interfaces:**
- Consumes: `Sys.Linux.Proc.NetDev` (Task 8), `Controls.Rate` (Task 3), `Sys.Mon.Server` (Task 4), `Unit.Bandwidth`, `Unit.Time`.
- Produces:
  - `Sys.Mon.NetBw` implements `Sys.Mon.Sampler`.
  - `Sys.Mon.NetBw.Reading.t()` — `%Sys.Mon.NetBw.Reading{instant: Unit.Bandwidth.t() | nil, smoothed: Unit.Bandwidth.t() | nil}`
  - `Sys.Mon.NetBw.child_spec(term()) :: Supervisor.child_spec()` (starts a `Server` named `Sys.Mon.NetBw`).
  - `Sys.Mon.NetBw.value() :: Reading.t()`
  - Period `11 s`, time constant `20 s`, telemetry event `[:sys, :mon, :net_bw]`.

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.Mon.NetBwTest do
  use ExUnit.Case, async: true

  alias Sys.Mon.NetBw
  alias Unit.Bandwidth

  test "init starts with no Rate baseline" do
    assert {:ok, nil} = NetBw.init()
  end

  test "the first sample skips (establishes a baseline)" do
    assert {:skip, {_count, _mono}} = NetBw.sample(nil)
  end

  test "value wraps the filtered float into Unit.Bandwidth" do
    spec = NetBw.child_spec([])
    {Sys.Mon.Server, :start_link, [opts]} = spec.start
    {:ok, _pid} = Sys.Mon.Server.start_link(opts)

    _ = Sys.Mon.Server.sample_now(Sys.Mon.NetBw)
    assert %NetBw.Reading{instant: nil, smoothed: nil} = NetBw.value()
  end

  test "child_spec uses an 11s period and 20s time constant" do
    spec = NetBw.child_spec([])
    {Sys.Mon.Server, :start_link, [opts]} = spec.start
    assert Unit.Time.as_s(opts.period) == 11
    assert Unit.Time.as_s(opts.tau) == 20
    assert opts.telemetry_event == [:sys, :mon, :net_bw]
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/mon/net_bw_test.exs`
Expected: FAIL — `Sys.Mon.NetBw.init/0 is undefined`.

- [ ] **Step 3: Write the implementation**

```elixir
defmodule Sys.Mon.NetBw do
  @moduledoc """
  Monitors instantaneous network bandwidth (the soft β_net_bw signal).

  Samples cumulative rx+tx bytes across non-loopback interfaces from
  `/proc/net/dev` every 11 seconds and differentiates them into bytes/sec via
  `Controls.Rate` (the first read only establishes a baseline). The rate series is
  smoothed with a 20-second time constant. Readings are `Unit.Bandwidth`.

  Telemetry: `[:sys, :mon, :net_bw]` with measurements `%{instant: float, smoothed: float}` (bytes/sec).
  """

  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.NetDev
  alias Controls.Rate
  alias Sys.Mon.Server
  alias Unit.Bandwidth
  alias Unit.Time

  @period Time.s(11)
  @tau Time.s(20)
  @event [:sys, :mon, :net_bw]

  defmodule Reading do
    @moduledoc "Instantaneous and filtered net-bandwidth readings."
    @type t :: %__MODULE__{instant: Bandwidth.t() | nil, smoothed: Bandwidth.t() | nil}
    defstruct [:instant, :smoothed]
  end

  @doc "The latest instantaneous + filtered network bandwidth."
  @spec value() :: Reading.t()
  def value do
    %Server.Reading{instant: instant, smoothed: smoothed} = Server.value(__MODULE__)
    %Reading{instant: to_bw(instant), smoothed: to_bw(smoothed)}
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    opts = %Server.Opts{
      sampler: __MODULE__,
      period: @period,
      tau: @tau,
      name: __MODULE__,
      telemetry_event: @event
    }

    %{id: __MODULE__, start: {Server, :start_link, [opts]}}
  end

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(rate_state) do
    case NetDev.read_total() do
      {:ok, bytes} ->
        Rate.compute(rate_state, bytes, System.monotonic_time(:millisecond))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_bw(float() | nil) :: Bandwidth.t() | nil
  defp to_bw(nil), do: nil
  defp to_bw(bytes_per_sec), do: Bandwidth.bps(round(bytes_per_sec))
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/mon/net_bw_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/sys/mon/net_bw.ex test/sys/mon/net_bw_test.exs
git commit -m "feat(sys.mon): add NetBw monitor (/proc/net/dev rate)"
```

---

### Task 13: `Sys.Mon` supervisor + `readings/0`, and wire into the application

Supervises the four monitors and exposes one aggregate getter for the scheduler. Then add `:telemetry` as an explicit dependency (we call `:telemetry.execute/3` directly), start `Sys.Mon` from `Hyper.Application`, and update the docs groups.

**Files:**
- Create: `lib/sys/mon.ex`
- Modify: `lib/hyper/application.ex` (add `Sys.Mon` to the supervision children)
- Modify: `mix.exs` (add `{:telemetry, "~> 1.3"}`; add a `Monitoring` group in `groups_for_modules`)
- Test: `test/sys/mon_test.exs`

**Interfaces:**
- Consumes: `Sys.Mon.Cpu` (Task 9), `Sys.Mon.Mem` (Task 10), `Sys.Mon.DiskBw` (Task 11), `Sys.Mon.NetBw` (Task 12).
- Produces:
  - `Sys.Mon.start_link(term()) :: Supervisor.on_start()`
  - `Sys.Mon.readings() :: %{cpu: Sys.Mon.Server.Reading.t(), mem: Sys.Mon.Mem.Reading.t(), disk_bw: Sys.Mon.DiskBw.Reading.t(), net_bw: Sys.Mon.NetBw.Reading.t()}`

- [ ] **Step 1: Write the failing test**

```elixir
defmodule Sys.MonTest do
  use ExUnit.Case, async: false

  alias Sys.Mon

  test "starts all four monitors under one supervisor" do
    start_supervised!(Mon)

    for name <- [Sys.Mon.Cpu, Sys.Mon.Mem, Sys.Mon.DiskBw, Sys.Mon.NetBw] do
      assert is_pid(Process.whereis(name)), "expected #{inspect(name)} to be running"
    end
  end

  test "readings/0 returns one reading per metric" do
    start_supervised!(Mon)

    assert %{cpu: %Sys.Mon.Server.Reading{}, mem: %Sys.Mon.Mem.Reading{}} = Mon.readings()
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `mix test test/sys/mon_test.exs`
Expected: FAIL — `Sys.Mon.__struct__/... `/`Sys.Mon` undefined (no `start_link`).

- [ ] **Step 3: Write the supervisor**

```elixir
defmodule Sys.Mon do
  @moduledoc """
  Supervises this node's real-time soft-metric monitors and exposes their current
  readings to the scheduler.

  Each child is an independent `Sys.Mon.Server` sampling one metric on its own
  prime-second period (`Cpu` 2 s, `Mem` 5 s, `DiskBw` 7 s, `NetBw` 11 s — pairwise
  coprime, so their tick phases rarely align) and low-pass-filtering the result.
  `one_for_one`: a crash in one monitor never disturbs the others.

  Telemetry events emitted by the children:

    * `[:sys, :mon, :cpu]`     — CPU utilization fraction
    * `[:sys, :mon, :mem]`     — used memory (bytes)
    * `[:sys, :mon, :disk_bw]` — disk bandwidth (bytes/sec)
    * `[:sys, :mon, :net_bw]`  — net bandwidth (bytes/sec)

  Each carries measurements `%{instant: float, smoothed: float}`.
  """

  use Supervisor

  alias Sys.Mon.{Cpu, DiskBw, Mem, NetBw}

  @doc "Start the monitor supervisor."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg) do
    Supervisor.init([Cpu, Mem, DiskBw, NetBw], strategy: :one_for_one)
  end

  @typedoc "A snapshot of every monitored soft metric."
  @type readings :: %{
          cpu: Sys.Mon.Server.Reading.t(),
          mem: Mem.Reading.t(),
          disk_bw: DiskBw.Reading.t(),
          net_bw: NetBw.Reading.t()
        }

  @doc "The current instantaneous + filtered reading for every monitored metric."
  @spec readings() :: readings()
  def readings do
    %{cpu: Cpu.value(), mem: Mem.value(), disk_bw: DiskBw.value(), net_bw: NetBw.value()}
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `mix test test/sys/mon_test.exs`
Expected: PASS (2 tests).

- [ ] **Step 5: Add the explicit `:telemetry` dependency**

In `mix.exs`, in `defp deps`, add the entry (keep the list alphabetically grouped as the surrounding entries are):

```elixir
{:telemetry, "~> 1.3"},
```

- [ ] **Step 6: Start `Sys.Mon` from the application**

In `lib/hyper/application.ex`, add `Sys.Mon` as the last entry of the `children` list:

```elixir
    children = [
      # The image-lineage database. Started first so the rest of the node can
      # query images/leases on boot.
      Hyper.Img.Db.Repo,
      # Form the BEAM cluster (Distributed Erlang) so Horde's `members: :auto`
      # can discover peer nodes. Gossip strategy in dev — see config/config.exs.
      {Cluster.Supervisor, [topologies, [name: Hyper.ClusterSupervisor]]},
      # This machine's participation in the cluster: owns the cluster-wide VM
      # registry and the local supervisor that runs this node's microVMs.
      Hyper.Node,
      # Per-node real-time soft-metric monitors (CPU/mem/disk/net), feeding the
      # scheduler's β-budget decisions.
      Sys.Mon
    ]
```

- [ ] **Step 7: Add the `Monitoring` docs group**

In `mix.exs`, inside `groups_for_modules`, add after the `System:` group:

```elixir
        Controls: [
          Controls.Ewma,
          Controls.Rate
        ],
        Monitoring: [
          Sys.Mon,
          Sys.Mon.Sampler,
          Sys.Mon.Server,
          Sys.Mon.Cpu,
          Sys.Mon.Mem,
          Sys.Mon.DiskBw,
          Sys.Mon.NetBw,
          Sys.Linux.Proc.Stat,
          Sys.Linux.Proc.Meminfo,
          Sys.Linux.Proc.Diskstats,
          Sys.Linux.Proc.NetDev
        ],
```

- [ ] **Step 8: Fetch deps and verify compile + full suite**

Run:
```bash
mix deps.get
mix compile --warnings-as-errors --force
mix test --warnings-as-errors
```
Expected: `:telemetry` resolves (already in the lock at 1.4.2), clean compile, all tests pass.

- [ ] **Step 9: Commit**

```bash
git add lib/sys/mon.ex test/sys/mon_test.exs lib/hyper/application.ex mix.exs mix.lock
git commit -m "feat(sys.mon): supervise monitors, wire into application, add telemetry dep"
```

---

### Task 14: Documentation page + final `mix check`

A cookbook page documenting the soft-metric monitoring subsystem and the LPF, plus the final strict gate (dialyzer included).

**Files:**
- Create: `docs/cookbook/monitoring.md`
- Modify: `mix.exs` (add the page to `extras`)

**Interfaces:** none (docs + verification only).

- [ ] **Step 1: Write the cookbook page**

```markdown
# Soft-Metric Monitoring

`Hyper`'s scheduler filters candidate nodes by their **soft (β) budgets** —
`vcpus`, `disk_bw`, `net_bw` — which, unlike the hard (α) budgets, cannot be
predicted from VM specs and must be *measured* in real time (see
[Architecture → Budgets](architecture.md)). The `Sys.Mon` subsystem performs
that measurement on every node.

## Monitors

`Sys.Mon` supervises one process per metric, each sampling `/proc` directly (no
`:os_mon` — same approach as `Sys.Linux.Proc.Mounts`):

| Monitor          | Source            | Period | Unit              |
|------------------|-------------------|--------|-------------------|
| `Sys.Mon.Cpu`    | `/proc/stat`      | 2 s    | fraction `0.0..1.0` |
| `Sys.Mon.Mem`    | `/proc/meminfo`   | 5 s    | `Unit.Information` |
| `Sys.Mon.DiskBw` | `/proc/diskstats` | 7 s    | `Unit.Bandwidth`  |
| `Sys.Mon.NetBw`  | `/proc/net/dev`   | 11 s   | `Unit.Bandwidth`  |

The periods are **prime seconds** and therefore pairwise coprime, so the four
sample phases rarely coincide — spreading the (already tiny) `/proc` read cost
out over time. Primality is only a phase-decorrelation trick; the parameter that
governs *responsiveness* is the filter time constant `τ` (and Nyquist: each
period is well under `τ`, so we never alias the dynamics we care about).

## The low-pass filter

Raw `/proc` readings are noisy. Each monitor smooths its stream with
`Controls.Ewma`, a first-order exponential moving average — the discrete form of
the classic analog low-pass filter `τ·ẏ + y = x`:

$$
\alpha = 1 - e^{-\Delta t / \tau}, \qquad y_n = \alpha\,x_n + (1-\alpha)\,y_{n-1}
$$

The gain `α` is recomputed from the **measured** `Δt` (via a monotonic clock) on
every sample, so the cutoff frequency stays pinned at `1/(2πτ)` regardless of
BEAM scheduler jitter or the differing per-monitor periods. Using a hardcoded
`α` instead would let the effective cutoff wander with timing noise — the most
common way an EMA-as-LPF goes subtly wrong.

`τ` is the only tuning knob: the output reaches ~63 % of a step change after one
`τ` and ~95 % after `3τ`. CPU and memory use `τ = 30 s`; bandwidth uses
`τ = 20 s`.

## Reading the values

The scheduler reads a node's current load synchronously:

```elixir
%{cpu: cpu, mem: mem, disk_bw: disk, net_bw: net} = Sys.Mon.readings()
cpu.smoothed      # filtered CPU utilization, 0.0..1.0 (nil before the first sample)
cpu.instant       # the latest raw sample
```

Every monitor also emits a `:telemetry` event per sample —
`[:sys, :mon, :cpu | :mem | :disk_bw | :net_bw]` with measurements
`%{instant: float, smoothed: float}` — for export to an observability backend.

## Extending

Adding a metric is mechanical: implement `Sys.Mon.Sampler` over the relevant
`/proc` file (reusing `Controls.Rate` if the source is a cumulative counter), give
it a `child_spec/1` that starts a `Sys.Mon.Server`, and add it to the `Sys.Mon`
supervisor's child list with its own prime period.
```

- [ ] **Step 2: Register the page in `mix.exs`**

In `mix.exs`, add it to `extras` (after the architecture entry) and to the `Cookbook` group is automatic via the existing `~r/docs\/cookbook\/.*/` matcher:

```elixir
      extras: [
        "README.md",
        "docs/cookbook/intro.md",
        "docs/cookbook/architecture.md",
        "docs/cookbook/monitoring.md"
      ],
```

- [ ] **Step 3: Run the full strict gate**

Run: `mix check`
Expected: every stage passes — `format --check-formatted`, `compile --warnings-as-errors --force`, `credo --strict`, `test --warnings-as-errors`, and `dialyzer` (no `unmatched_returns`/`extra_return`/`missing_return` findings).

> If dialyzer flags an unmatched return, bind it with `_ = …` (as `Server.init/1` and `handle_info/2` already do for `Process.send_after`). If it flags a contract, reconcile the `@spec` with the actual return — do not relax the flags.

- [ ] **Step 4: Commit**

```bash
git add docs/cookbook/monitoring.md mix.exs
git commit -m "docs(sys.mon): document soft-metric monitoring and the LPF"
```

---

## Self-Review

**1. Spec coverage**

- "New package `lib/sys`, migrate `lib/hyper/sys`" → Task 1 (move + global rename, all 9 files + 6 call sites + mix.exs).
- "New `Sys.Mon` package" → Tasks 4 & 13 (`Sampler`/`Server` engine, `Sys.Mon` supervisor).
- "`Sys.Mon.Cpu`, `Sys.Mon.Mem`, etc." → Tasks 9–12 (Cpu, Mem, DiskBw, NetBw — the architecture's β metrics plus Mem, per the chosen scope).
- "Read instantaneous load periodically, prime periods to minimize overlap" → periods 2/5/7/11 s (pairwise coprime), self-scheduled in `Server` (Task 4); rationale in the doc (Task 14).
- "EXP moving average / LPF" → `Controls.Ewma` (Task 2), with the variable-`Δt` gain.
- "Research great packages / catch bad ideas early" → "Research & Design Rationale" section (os_mon and telemetry_poller rejected with reasons; eight EWMA/sampling pitfalls enumerated and each defended against in code).
- "Good documentation and `@specs`" → every public function has `@spec`/`@doc`/`@moduledoc`; `monitoring.md` cookbook page; `mix check` enforces it.
- "Elixir 1.20 good types" → typed structs (`Opts`, `Reading`, `Snapshot`, `State`) with `@type`; domain `Unit.*` at boundaries; strict dialyzer flags honored.

**2. Placeholder scan**

No `TBD`/`TODO`/"add error handling"/"similar to Task N" — every code step shows full code; every command states its expected outcome; the one cross-task abstraction (`Controls.Rate`) is shared by DiskBw and NetBw rather than duplicated.

**3. Type consistency**

- `Sys.Mon.Server.value/1` and `sample_now/1` return `Server.Reading.t()` everywhere; Cpu returns it directly; Mem/DiskBw/NetBw destructure it (`%Server.Reading{instant:, smoothed:}`) and re-wrap — field names match the struct defined in Task 4.
- `Sys.Mon.Sampler` callbacks (`init/0`, `sample/1`) and their return shapes (`{:ok, float, private}` / `{:skip, private}` / `{:error, term}`) are consistent across all four sampler implementations and the `Server.do_sample/1` that consumes them.
- `Controls.Rate.compute/3` state shape `{count, mono_ms} | nil` matches how DiskBw/NetBw thread it as their sampler-private state.
- `Unit.Time.as_ms/1`, `Unit.Information.as_bytes/1`/`bytes/1`/`kib/1`, `Unit.Bandwidth.bps/1` match the existing `Unit.*` APIs read from source.
- `Sys.Linux.Proc.Stat.Snapshot` / `Meminfo.Snapshot` field names (`idle`/`total`, `total`/`available`) are consistent between parser, tests, and the sampler that destructures them.
```
