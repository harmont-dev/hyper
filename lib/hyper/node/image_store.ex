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
