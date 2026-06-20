defmodule Hyper.Node.Budget.Advertiser do
  @moduledoc """
  Owns this node's entry in `Hyper.Cluster.Budget`. Registers a fresh
  `Hyper.Node.Budget.NodeState` on start and re-publishes it on demand
  (`publish/0`, called on every allocation by `Hyper.Node.Budget.Hard`) and on a
  periodic heartbeat (keeps drifting soft-load fresh and restores the
  registration if the registry restarted).
  """

  use GenServer

  alias Hyper.Cluster.Budget
  alias Hyper.Node.Budget.NodeState

  @heartbeat_ms 5_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Recompute and re-publish this node's state now."
  @spec publish() :: :ok
  def publish, do: GenServer.cast(__MODULE__, :publish)

  @impl true
  def init(_opts) do
    advertise()
    _ = Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:ok, nil}
  end

  @impl true
  def handle_cast(:publish, state) do
    advertise()
    {:noreply, state}
  end

  @impl true
  def handle_info(:heartbeat, state) do
    advertise()
    _ = Process.send_after(self(), :heartbeat, @heartbeat_ms)
    {:noreply, state}
  end

  # Publish the current NodeState, (re-)registering if we have no entry yet.
  @spec advertise() :: :ok
  defp advertise do
    ns = NodeState.build()

    case Horde.Registry.update_value(Budget.name(), Budget.key(), fn _old -> ns end) do
      :error ->
        {:ok, _} = Horde.Registry.register(Budget.name(), Budget.key(), ns)
        :ok

      _updated ->
        :ok
    end
  end
end
