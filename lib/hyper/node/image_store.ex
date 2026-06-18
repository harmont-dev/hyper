defmodule Hyper.Node.ImageStore do
  @moduledoc """
  Node-local content-addressed blob cache.

  Manages blobs and nothing else: fetch-on-miss from the truth tier, local
  caching, refcount leases, and LRU eviction. One `Blob` process per cached hash
  owns that blob's refcount/leases; the `Janitor` evicts cold blobs.

  It does **not** do copy-on-write provisioning or jail staging — that lives in
  the VM provisioning layer, which *uses* this store to obtain base blobs by hash.

  Supervises:

    * `BlobRegistry`   — `{:blob, hash}` -> `Hyper.Node.ImageStore.Blob` pid
    * `TaskSupervisor` — fetches / uploads
    * `BlobSupervisor` — one `Blob` per cached blob
    * `Janitor`        — LRU eviction + GC

  Skeleton only: the facade raises until implemented.
  """

  use Supervisor

  alias Hyper.Node.ImageStore.Janitor

  @blob_registry Hyper.Node.ImageStore.BlobRegistry
  @blob_supervisor Hyper.Node.ImageStore.BlobSupervisor
  @task_supervisor Hyper.Node.ImageStore.TaskSupervisor

  @typedoc "A content hash addressing an immutable blob, e.g. \"sha256:abc...\"."
  @type hash :: String.t()

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
  Ensure the blob `hash` is present locally (fetching on a miss) and lease it to
  `owner` — bumps the refcount and monitors `owner` so the lease auto-releases
  when it dies. Returns the local path of the cached blob.
  """
  @spec acquire(hash(), owner :: pid()) :: {:ok, Path.t()} | {:error, term()}
  def acquire(_hash, _owner), do: raise("not implemented")

  @doc "Release `owner`'s lease on the blob `hash`."
  @spec release(hash(), owner :: pid()) :: :ok
  def release(_hash, _owner), do: raise("not implemented")

  @doc "Ingest a local file as a content-addressed blob; returns its hash."
  @spec put(src :: Path.t()) :: {:ok, hash()} | {:error, term()}
  def put(_src), do: raise("not implemented")

  @doc "Current cache statistics."
  @spec stats() :: stats()
  def stats, do: raise("not implemented")
end
