defmodule Hyper.SingleNodeGuard do
  @moduledoc """
  Enforces that this node is the only node in the cluster.

  Some subsystems are correct only when no peers are present (for example, a
  single-writer local datastore). Start this guard whenever such a subsystem is
  active. It:

    * refuses to start if any peers are already connected, and
    * halts the node via `System.stop/1` if a peer later joins,

  preventing the unsafe multi-node configuration from continuing.

  The guard is deliberately decoupled from any particular subsystem - the
  decision of whether to start it belongs to the application supervisor. `init/1`
  accepts a 0-arity `:peers` function (default `&Node.list/0`) so the decision
  logic can be exercised without a live cluster.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    peers_fun = Keyword.get(opts, :peers, &Node.list/0)
    GenServer.start_link(__MODULE__, peers_fun, name: __MODULE__)
  end

  @impl true
  def init(peers_fun) when is_function(peers_fun, 0) do
    _ = :net_kernel.monitor_nodes(true)

    case peers_fun.() do
      [] ->
        Logger.info("single-node guard armed; this node must remain the only node")
        {:ok, %{peers: peers_fun}}

      peers ->
        Logger.critical(
          "single-node guard: cluster already has peers (#{inspect(peers)}); " <>
            "this node requires single-node operation. Refusing to start."
        )

        {:stop, {:multi_node, peers}}
    end
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.critical(
      "single-node guard: peer #{inspect(node)} joined the cluster; " <>
        "this node requires single-node operation. Halting to protect integrity."
    )

    System.stop(1)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}
end
