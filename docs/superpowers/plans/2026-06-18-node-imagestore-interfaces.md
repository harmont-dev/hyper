# Node.ImageStore Interfaces Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Define the complete interface surface (behaviours, module seams, typed stubs, supervision wiring) of the `Hyper.Node.ImageStore` subtree, with no implementation logic.

**Architecture:** A node-local supervisor (`Hyper.Node.ImageStore`) owns a blob registry, a blob `DynamicSupervisor`, a `Task.Supervisor`, and a `Janitor`. Two behaviours (`Hyper.Node.BlobSource`, `Hyper.Node.Cow`) define the pluggable transport and copy-on-write seams. All public functions exist with full `@spec`s but their bodies are stubs that `raise "not implemented"`; only the supervision tree and trivial GenServer `init/1` callbacks are real, so the tree starts but does nothing.

**Tech Stack:** Elixir, OTP (`Supervisor`, `GenServer`, `DynamicSupervisor`, `Registry`, `Task.Supervisor`), ExUnit.

## Global Constraints

- Elixir `~> 1.19` (project compiles on OTP 28). Copied verbatim from `mix.exs`.
- Namespaces: node-scoped modules live under `Hyper.Node.*`; the existing VM-spec modules under `Hyper.Vm.*`. Follow the established `lib/hyper/node/...` and `test/hyper/node/...` layout.
- **No implementation logic.** Every behavioural public function body is exactly `raise "not implemented"`. The only real code permitted: supervision child lists, `start_link/1`, `child_spec/1`, and trivial `init/1` callbacks that return a constant state.
- Stub convention is uniform: `raise "not implemented"` (raises `RuntimeError` with message `"not implemented"`). Tests assert this exact message.
- Test command form: `mix test <path>` (config `:test` env already disables the OTel exporter — no env vars needed).
- The `:hyper` application is started automatically during `mix test`; therefore `Hyper.Node` (and, after Task 6, `Hyper.Node.ImageStore`) is already running in the test VM. Interface tests must **not** start a second copy of any named singleton — test pure functions (`init/1`, `child_spec/1`, exports, stub raises) or observe the already-running app tree.

---

## File Structure

- `lib/hyper/node/blob_source.ex` — `Hyper.Node.BlobSource` behaviour: the truth-tier transport seam (resolve/fetch/put).
- `lib/hyper/node/cow.ex` — `Hyper.Node.Cow` behaviour: the copy-on-write provisioning seam (available?/clone/destroy).
- `lib/hyper/node/image_store/blob.ex` — `Hyper.Node.ImageStore.Blob` GenServer skeleton: one process per cached blob (acquire/release/try_evict).
- `lib/hyper/node/image_store/janitor.ex` — `Hyper.Node.ImageStore.Janitor` GenServer skeleton: eviction/GC sweep.
- `lib/hyper/node/image_store.ex` — `Hyper.Node.ImageStore` Supervisor + public API facade (provision/release/snapshot/stats) and the tree wiring.
- `lib/hyper/node.ex` — MODIFY: add `Hyper.Node.ImageStore` to the node supervision tree before `VMSupervisor`.
- `test/hyper/node/blob_source_test.exs`, `test/hyper/node/cow_test.exs`, `test/hyper/node/image_store/blob_test.exs`, `test/hyper/node/image_store/janitor_test.exs`, `test/hyper/node/image_store_test.exs`, `test/hyper/node_test.exs` — one test file per module.

---

### Task 1: `Hyper.Node.BlobSource` behaviour

**Files:**
- Create: `lib/hyper/node/blob_source.ex`
- Create: `test/hyper/node/blob_source_test.exs`
- Delete: `test/hyper_test.exs` (stale generated test calling the non-existent `Hyper.hello/0`; removing it keeps `mix test` green)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Hyper.Node.BlobSource` behaviour with callbacks:
    - `resolve(ref :: String.t()) :: {:ok, hash :: String.t()} | {:error, term()}`
    - `fetch(hash :: String.t(), dest :: Path.t()) :: :ok | {:error, term()}`
    - `put(src :: Path.t()) :: {:ok, hash :: String.t()} | {:error, term()}`
  - Types `Hyper.Node.BlobSource.ref()` and `Hyper.Node.BlobSource.hash()` (both `String.t()`).

- [ ] **Step 1: Remove the stale generated test**

```bash
git rm test/hyper_test.exs
git commit -m "chore: drop stale generated Hyper.hello/0 test"
```

- [ ] **Step 2: Write the failing test**

Create `test/hyper/node/blob_source_test.exs`:

```elixir
defmodule Hyper.Node.BlobSourceTest do
  use ExUnit.Case, async: true

  test "declares the truth-tier callbacks" do
    callbacks = Hyper.Node.BlobSource.behaviour_info(:callbacks)

    assert {:resolve, 1} in callbacks
    assert {:fetch, 2} in callbacks
    assert {:put, 1} in callbacks
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `mix test test/hyper/node/blob_source_test.exs`
Expected: FAIL — `Hyper.Node.BlobSource.behaviour_info/1 is undefined (module Hyper.Node.BlobSource is not available)`.

- [ ] **Step 4: Write the behaviour**

Create `lib/hyper/node/blob_source.ex`:

```elixir
defmodule Hyper.Node.BlobSource do
  @moduledoc """
  Behaviour for the truth tier — where content-addressed artifacts (base images,
  snapshots) durably live and are fetched from. Implementations will include S3,
  NFS, and desync. Interface only; no implementation yet.
  """

  @typedoc "A logical image reference, e.g. \"ubuntu:22.04\"."
  @type ref :: String.t()

  @typedoc "A content hash addressing an immutable blob, e.g. \"sha256:abc...\"."
  @type hash :: String.t()

  @doc "Resolve a logical ref to the content hash it currently points at."
  @callback resolve(ref()) :: {:ok, hash()} | {:error, term()}

  @doc "Download the blob `hash` into the local file `dest`."
  @callback fetch(hash(), dest :: Path.t()) :: :ok | {:error, term()}

  @doc "Upload local file `src` as a content-addressed blob; returns its hash."
  @callback put(src :: Path.t()) :: {:ok, hash()} | {:error, term()}
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/hyper/node/blob_source_test.exs`
Expected: PASS (1 test).

- [ ] **Step 6: Commit**

```bash
git add lib/hyper/node/blob_source.ex test/hyper/node/blob_source_test.exs
git commit -m "feat: add Hyper.Node.BlobSource behaviour"
```

---

### Task 2: `Hyper.Node.Cow` behaviour

**Files:**
- Create: `lib/hyper/node/cow.ex`
- Create: `test/hyper/node/cow_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Hyper.Node.Cow` behaviour with callbacks:
    - `available?() :: boolean()`
    - `clone(base :: Path.t(), dest :: Path.t()) :: :ok | {:error, term()}`
    - `destroy(volume :: Path.t()) :: :ok | {:error, term()}`

- [ ] **Step 1: Write the failing test**

Create `test/hyper/node/cow_test.exs`:

```elixir
defmodule Hyper.Node.CowTest do
  use ExUnit.Case, async: true

  test "declares the copy-on-write callbacks" do
    callbacks = Hyper.Node.Cow.behaviour_info(:callbacks)

    assert {:available?, 0} in callbacks
    assert {:clone, 2} in callbacks
    assert {:destroy, 1} in callbacks
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hyper/node/cow_test.exs`
Expected: FAIL — `module Hyper.Node.Cow is not available`.

- [ ] **Step 3: Write the behaviour**

Create `lib/hyper/node/cow.ex`:

```elixir
defmodule Hyper.Node.Cow do
  @moduledoc """
  Behaviour for copy-on-write provisioning of a per-VM writable rootfs from a
  read-only base. Implementations will include reflink (single filesystem) and
  dm-thin (external origin). Interface only; no implementation yet.
  """

  @doc "Whether this mechanism is usable on the current host."
  @callback available?() :: boolean()

  @doc "Create a writable copy-on-write clone of `base` at `dest`."
  @callback clone(base :: Path.t(), dest :: Path.t()) :: :ok | {:error, term()}

  @doc "Tear down a clone previously created at `volume`."
  @callback destroy(volume :: Path.t()) :: :ok | {:error, term()}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hyper/node/cow_test.exs`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/cow.ex test/hyper/node/cow_test.exs
git commit -m "feat: add Hyper.Node.Cow behaviour"
```

---

### Task 3: `Hyper.Node.ImageStore.Blob` skeleton

**Files:**
- Create: `lib/hyper/node/image_store/blob.ex`
- Create: `test/hyper/node/image_store/blob_test.exs`

**Interfaces:**
- Consumes: nothing (registers under `Hyper.Node.ImageStore.BlobRegistry`, which Task 5 starts).
- Produces:
  - `Hyper.Node.ImageStore.Blob.start_link(hash :: String.t()) :: GenServer.on_start()`
  - `Hyper.Node.ImageStore.Blob.child_spec(hash :: String.t()) :: Supervisor.child_spec()` with `id: {Hyper.Node.ImageStore.Blob, hash}` and `restart: :temporary`
  - `Hyper.Node.ImageStore.Blob.acquire(hash :: String.t(), owner :: pid()) :: {:ok, Path.t()} | {:error, term()}` (stub)
  - `Hyper.Node.ImageStore.Blob.release(hash :: String.t(), owner :: pid()) :: :ok` (stub)
  - `Hyper.Node.ImageStore.Blob.try_evict(hash :: String.t()) :: :evicted | :pinned` (stub)
  - `init/1` returns `{:ok, %{hash: hash}}`

- [ ] **Step 1: Write the failing test**

Create `test/hyper/node/image_store/blob_test.exs`:

```elixir
defmodule Hyper.Node.ImageStore.BlobTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.ImageStore.Blob

  test "exposes the per-blob lifecycle API" do
    assert function_exported?(Blob, :start_link, 1)
    assert function_exported?(Blob, :child_spec, 1)
    assert function_exported?(Blob, :acquire, 2)
    assert function_exported?(Blob, :release, 2)
    assert function_exported?(Blob, :try_evict, 1)
  end

  test "child_spec is keyed by hash and temporary" do
    spec = Blob.child_spec("sha256:abc")

    assert spec.id == {Blob, "sha256:abc"}
    assert spec.restart == :temporary
  end

  test "init carries the blob hash" do
    assert Blob.init("sha256:abc") == {:ok, %{hash: "sha256:abc"}}
  end

  test "lifecycle functions are not implemented yet" do
    assert_raise RuntimeError, "not implemented", fn -> Blob.acquire("sha256:abc", self()) end
    assert_raise RuntimeError, "not implemented", fn -> Blob.release("sha256:abc", self()) end
    assert_raise RuntimeError, "not implemented", fn -> Blob.try_evict("sha256:abc") end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hyper/node/image_store/blob_test.exs`
Expected: FAIL — `module Hyper.Node.ImageStore.Blob is not available`.

- [ ] **Step 3: Write the skeleton**

Create `lib/hyper/node/image_store/blob.ex`:

```elixir
defmodule Hyper.Node.ImageStore.Blob do
  @moduledoc """
  One process per cached base blob — the authority for that blob's fetch state,
  refcount, and leases. Skeleton only: the lifecycle API raises until implemented.
  """

  use GenServer

  @type hash :: String.t()

  @registry Hyper.Node.ImageStore.BlobRegistry

  @doc "Start the process for `hash`, registered under the blob registry."
  @spec start_link(hash()) :: GenServer.on_start()
  def start_link(hash) when is_binary(hash) do
    GenServer.start_link(__MODULE__, hash, name: via(hash))
  end

  @doc false
  def child_spec(hash) do
    %{id: {__MODULE__, hash}, start: {__MODULE__, :start_link, [hash]}, restart: :temporary}
  end

  @doc "Ensure the blob is local and lease it to `owner` (bump refcount, monitor owner)."
  @spec acquire(hash(), owner :: pid()) :: {:ok, Path.t()} | {:error, term()}
  def acquire(_hash, _owner), do: raise("not implemented")

  @doc "Release `owner`'s lease on the blob."
  @spec release(hash(), owner :: pid()) :: :ok
  def release(_hash, _owner), do: raise("not implemented")

  @doc "Evict the blob if no live lease holds it; reports the outcome."
  @spec try_evict(hash()) :: :evicted | :pinned
  def try_evict(_hash), do: raise("not implemented")

  @impl true
  def init(hash), do: {:ok, %{hash: hash}}

  defp via(hash), do: {:via, Registry, {@registry, {:blob, hash}}}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hyper/node/image_store/blob_test.exs`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/image_store/blob.ex test/hyper/node/image_store/blob_test.exs
git commit -m "feat: add Hyper.Node.ImageStore.Blob skeleton"
```

---

### Task 4: `Hyper.Node.ImageStore.Janitor` skeleton

**Files:**
- Create: `lib/hyper/node/image_store/janitor.ex`
- Create: `test/hyper/node/image_store/janitor_test.exs`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Hyper.Node.ImageStore.Janitor.start_link(opts :: keyword()) :: GenServer.on_start()` (registered as `Hyper.Node.ImageStore.Janitor`)
  - `Hyper.Node.ImageStore.Janitor.sweep() :: :ok` (stub)
  - `init/1` returns `{:ok, %{}}`

- [ ] **Step 1: Write the failing test**

Create `test/hyper/node/image_store/janitor_test.exs`:

```elixir
defmodule Hyper.Node.ImageStore.JanitorTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.ImageStore.Janitor

  test "exposes the sweep API" do
    assert function_exported?(Janitor, :start_link, 1)
    assert function_exported?(Janitor, :sweep, 0)
  end

  test "init starts with empty state" do
    assert Janitor.init([]) == {:ok, %{}}
  end

  test "sweep is not implemented yet" do
    assert_raise RuntimeError, "not implemented", fn -> Janitor.sweep() end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hyper/node/image_store/janitor_test.exs`
Expected: FAIL — `module Hyper.Node.ImageStore.Janitor is not available`.

- [ ] **Step 3: Write the skeleton**

Create `lib/hyper/node/image_store/janitor.ex`:

```elixir
defmodule Hyper.Node.ImageStore.Janitor do
  @moduledoc """
  Periodic LRU eviction + orphan GC across all cached blobs: reads the shared
  index and nudges `Hyper.Node.ImageStore.Blob` processes. Skeleton only:
  `sweep/0` raises until implemented.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run one eviction + GC pass now."
  @spec sweep() :: :ok
  def sweep, do: raise("not implemented")

  @impl true
  def init(_opts), do: {:ok, %{}}
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hyper/node/image_store/janitor_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/image_store/janitor.ex test/hyper/node/image_store/janitor_test.exs
git commit -m "feat: add Hyper.Node.ImageStore.Janitor skeleton"
```

---

### Task 5: `Hyper.Node.ImageStore` supervisor + facade

**Files:**
- Create: `lib/hyper/node/image_store.ex`
- Create: `test/hyper/node/image_store_test.exs`

**Interfaces:**
- Consumes:
  - `Hyper.Node.ImageStore.Janitor` (started as a child)
  - Child process names it defines: `Hyper.Node.ImageStore.BlobRegistry` (a `Registry`, consumed by `Hyper.Node.ImageStore.Blob` from Task 3), `Hyper.Node.ImageStore.BlobSupervisor` (a `DynamicSupervisor`), `Hyper.Node.ImageStore.TaskSupervisor` (a `Task.Supervisor`).
- Produces:
  - `Hyper.Node.ImageStore.start_link(opts :: keyword()) :: Supervisor.on_start()` (registered as `Hyper.Node.ImageStore`)
  - `Hyper.Node.ImageStore.provision(owner :: pid(), source(), jail_root :: Path.t()) :: {:ok, staged()} | {:error, term()}` (stub)
  - `Hyper.Node.ImageStore.release(owner :: pid()) :: :ok` (stub)
  - `Hyper.Node.ImageStore.snapshot(owner :: pid(), vm :: pid()) :: {:ok, snapshot_ref()} | {:error, term()}` (stub)
  - `Hyper.Node.ImageStore.stats() :: stats()` (stub)
  - Types: `source() :: Hyper.vm_source()`, `staged() :: %{kernel: Path.t(), rootfs: Path.t()}`, `snapshot_ref() :: String.t()`, `stats() :: %{bytes: non_neg_integer(), blobs: non_neg_integer(), evictions: non_neg_integer()}`
  - `init/1` returns a supervisor spec containing exactly 4 children.

- [ ] **Step 1: Write the failing test**

Create `test/hyper/node/image_store_test.exs`:

```elixir
defmodule Hyper.Node.ImageStoreTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.ImageStore

  test "exposes the provisioning facade" do
    assert function_exported?(ImageStore, :start_link, 1)
    assert function_exported?(ImageStore, :provision, 3)
    assert function_exported?(ImageStore, :release, 1)
    assert function_exported?(ImageStore, :snapshot, 2)
    assert function_exported?(ImageStore, :stats, 0)
  end

  test "init wires exactly four children" do
    assert {:ok, {_flags, children}} = ImageStore.init([])
    assert length(children) == 4
  end

  test "facade functions are not implemented yet" do
    src = {:image, kernel: "k", rootfs: "r"}

    assert_raise RuntimeError, "not implemented", fn -> ImageStore.provision(self(), src, "/jail") end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.release(self()) end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.snapshot(self(), self()) end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.stats() end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hyper/node/image_store_test.exs`
Expected: FAIL — `module Hyper.Node.ImageStore is not available`.

- [ ] **Step 3: Write the supervisor + facade**

Create `lib/hyper/node/image_store.ex`:

```elixir
defmodule Hyper.Node.ImageStore do
  @moduledoc """
  Node-local image/snapshot cache and copy-on-write provisioner.

  Supervises:

    * `BlobRegistry`   — `{:blob, hash}` -> `Hyper.Node.ImageStore.Blob` pid
    * `TaskSupervisor` — fetches / uploads
    * `BlobSupervisor` — one `Blob` per cached base
    * `Janitor`        — LRU eviction + GC

  The public functions are the seam other subsystems (e.g. `Hyper.Node.FireVMM.State`)
  call. Skeleton only: the facade raises until implemented.
  """

  use Supervisor

  alias Hyper.Node.ImageStore.Janitor

  @blob_registry Hyper.Node.ImageStore.BlobRegistry
  @blob_supervisor Hyper.Node.ImageStore.BlobSupervisor
  @task_supervisor Hyper.Node.ImageStore.TaskSupervisor

  @typedoc "What to materialise for a VM; resolved by the store into blobs."
  @type source :: Hyper.vm_source()

  @typedoc "Paths, relative to the jail root, of the staged artifacts."
  @type staged :: %{kernel: Path.t(), rootfs: Path.t()}

  @typedoc "A content-addressed handle to a published snapshot."
  @type snapshot_ref :: String.t()

  @typedoc "A point-in-time view of cache usage."
  @type stats :: %{
          bytes: non_neg_integer(),
          blobs: non_neg_integer(),
          evictions: non_neg_integer()
        }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @blob_registry},
      {Task.Supervisor, name: @task_supervisor},
      {DynamicSupervisor, name: @blob_supervisor, strategy: :one_for_one},
      Janitor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Stage a VM's kernel (hardlink) and a copy-on-write rootfs into `jail_root`,
  leasing the base blobs to `owner` (auto-released when `owner` dies). Returns
  the staged paths relative to the jail root.
  """
  @spec provision(owner :: pid(), source(), jail_root :: Path.t()) ::
          {:ok, staged()} | {:error, term()}
  def provision(_owner, _source, _jail_root), do: raise("not implemented")

  @doc "Release every lease held by `owner` and tear down its copy-on-write volumes."
  @spec release(owner :: pid()) :: :ok
  def release(_owner), do: raise("not implemented")

  @doc "Snapshot the running VM `vm`, publish it to the truth tier, return its ref."
  @spec snapshot(owner :: pid(), vm :: pid()) :: {:ok, snapshot_ref()} | {:error, term()}
  def snapshot(_owner, _vm), do: raise("not implemented")

  @doc "Current cache statistics."
  @spec stats() :: stats()
  def stats, do: raise("not implemented")
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hyper/node/image_store_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/hyper/node/image_store.ex test/hyper/node/image_store_test.exs
git commit -m "feat: add Hyper.Node.ImageStore supervisor and facade skeleton"
```

---

### Task 6: Wire `ImageStore` into the node tree

**Files:**
- Modify: `lib/hyper/node.ex:33-41` (the `init/1` child list)
- Create: `test/hyper/node_test.exs`

**Interfaces:**
- Consumes: `Hyper.Node.ImageStore` (started as a child; its default `child_spec/1` from `use Supervisor` is used via the bare module atom).
- Produces: a running `Hyper.Node.ImageStore` (and its children) under `Hyper.Node`, started before `Hyper.Node.VMSupervisor`.

- [ ] **Step 1: Write the failing test**

Create `test/hyper/node_test.exs`:

```elixir
defmodule Hyper.NodeTest do
  use ExUnit.Case, async: false

  # The :hyper application is already started, so Hyper.Node and its children
  # are running. Observe them rather than starting a second copy.

  test "ImageStore runs under the node tree" do
    assert is_pid(Process.whereis(Hyper.Node.ImageStore))
    assert Process.alive?(Process.whereis(Hyper.Node.ImageStore))
  end

  test "ImageStore children are running" do
    for name <- [
          Hyper.Node.ImageStore.BlobRegistry,
          Hyper.Node.ImageStore.TaskSupervisor,
          Hyper.Node.ImageStore.BlobSupervisor,
          Hyper.Node.ImageStore.Janitor
        ] do
      assert is_pid(Process.whereis(name)), "expected #{inspect(name)} to be running"
    end
  end

  test "VMSupervisor still runs alongside it" do
    assert is_pid(Process.whereis(Hyper.Node.VMSupervisor))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/hyper/node_test.exs`
Expected: FAIL — `Process.whereis(Hyper.Node.ImageStore)` returns `nil` (not yet wired into the tree), so the first assertion fails.

- [ ] **Step 3: Wire ImageStore into the node**

In `lib/hyper/node.ex`, the current `init/1` reads:

```elixir
  @impl true
  def init(_opts) do
    children = [
      {Horde.Registry, name: @registry, keys: :unique, members: :auto},
      {DynamicSupervisor, name: @vm_sup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
```

Replace it with (adds `Hyper.Node.ImageStore` before the VM supervisor so the cache is up before any VM provisions against it):

```elixir
  @impl true
  def init(_opts) do
    children = [
      {Horde.Registry, name: @registry, keys: :unique, members: :auto},
      Hyper.Node.ImageStore,
      {DynamicSupervisor, name: @vm_sup, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/hyper/node_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the full suite to verify nothing regressed**

Run: `mix test`
Expected: PASS — all interface tests green, no failures.

- [ ] **Step 6: Commit**

```bash
git add lib/hyper/node.ex test/hyper/node_test.exs
git commit -m "feat: start Hyper.Node.ImageStore under the node supervision tree"
```

---

## Self-Review

**1. Spec coverage** (interfaces for the `Node.ImageStore` tree):
- Truth-tier transport seam → Task 1 (`BlobSource` behaviour). ✓
- Copy-on-write seam → Task 2 (`Cow` behaviour). ✓
- Per-blob process (refcount/lease authority) interface → Task 3 (`Blob` skeleton). ✓
- Eviction/GC interface → Task 4 (`Janitor` skeleton). ✓
- Cache facade + supervision tree (`BlobRegistry`, `TaskSupervisor`, `BlobSupervisor`, `Janitor`) → Task 5. ✓
- Tree placed in the running node → Task 6. ✓
- Deliberately **out of scope** (no implementation): ETS index schema, fetch/clone/evict logic, the firecracker UDS client, `State.booting` calling `provision`, snapshot logic. These remain stubs/seams.

**2. Placeholder scan:** No "TBD"/"handle errors"/"similar to Task N". Every step has complete code or an exact command + expected output. Stub bodies are the intended deliverable (`raise "not implemented"`), not placeholders.

**3. Type consistency:**
- `hash :: String.t()` used identically in `BlobSource` (Task 1) and `Blob` (Task 3).
- `Blob.child_spec/1` id `{Hyper.Node.ImageStore.Blob, hash}` matches the test assertion in Task 3.
- Child names defined in Task 5 (`BlobRegistry`, `TaskSupervisor`, `BlobSupervisor`, `Janitor`) match: the `Blob` registry `@registry` in Task 3, and the Task 6 observation test.
- `source() :: Hyper.vm_source()` references the existing type in `lib/hyper.ex`.
- Facade arities (`provision/3`, `release/1`, `snapshot/2`, `stats/0`) are consistent between the Task 5 spec, code, and test.
