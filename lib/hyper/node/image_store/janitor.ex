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
