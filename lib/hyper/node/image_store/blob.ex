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
