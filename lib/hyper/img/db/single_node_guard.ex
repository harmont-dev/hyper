defmodule Hyper.Img.Db.SingleNodeGuard do
  @moduledoc """
  Enforces that the SQLite image-graph backend only ever runs on a node with
  no connected peers.

  A single-writer file database cannot be shared safely across cluster nodes,
  so this guard:

    * refuses to boot (stops with `{:multi_node_sqlite, peers}`) if peers are
      already connected when it starts, and
    * halts the node via `System.stop/1` if a peer joins while it is running,
      preventing concurrent writers from corrupting the database.

  Only started when `Hyper.Img.Db.Backend.sqlite?/0` is true.
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
        Logger.info("img db: SQLite backend active; single-node guard armed")
        {:ok, %{peers: peers_fun}}

      peers ->
        Logger.critical(
          "img db: SQLite backend is configured but the cluster already has peers " <>
            "(#{inspect(peers)}). SQLite cannot be shared across nodes; refusing to start."
        )

        {:stop, {:multi_node_sqlite, peers}}
    end
  end

  @impl true
  def handle_info({:nodeup, node}, state) do
    Logger.critical(
      "img db: SQLite backend active but peer #{inspect(node)} joined the cluster. " <>
        "SQLite is single-writer and cannot be shared safely. " <>
        "Halting to protect data integrity."
    )

    System.stop(1)
    {:noreply, state}
  end

  def handle_info({:nodedown, _node}, state), do: {:noreply, state}
  def handle_info(_msg, state), do: {:noreply, state}
end
