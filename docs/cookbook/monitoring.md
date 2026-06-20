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
