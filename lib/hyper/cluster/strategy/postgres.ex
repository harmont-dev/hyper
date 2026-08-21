defmodule Hyper.Cluster.Strategy.Postgres do
  @moduledoc """
  A libcluster strategy that discovers peers through the shared Postgres image
  database instead of a static host list or DNS.

  It implements the `Cluster.Strategy` contract as a `GenServer` and holds a
  single `Cluster.Strategy.State` for its lifetime. Two laws govern every poll
  tick:

    * **Heartbeat upsert** — this node writes (and refreshes) exactly one row in
      `cluster_nodes` keyed by its node name, stamping `updated_at = now()`. The
      row is idempotent: repeated ticks update the same row rather than
      accumulating.
    * **TTL-filtered discovery** — a peer is considered live only while its
      heartbeat is newer than `node_ttl` milliseconds. The strategy connects to
      every live peer other than itself and never disconnects, so a node that
      stops heartbeating simply ages out of future discovery without being
      forcibly removed.

  Both the heartbeat write and the peer read are wrapped in `try/rescue`: the
  database may not be reachable yet when the strategy starts, and a transient
  failure must degrade to a no-op tick rather than crash-loop the strategy.

  ## Config

  The strategy reads two optional keys from the `Cluster.Strategy.State`
  `:config` keyword list:

    * `:poll_interval` — milliseconds between ticks (default `5_000`).
    * `:node_ttl` — milliseconds a heartbeat stays live (default `15_000`).
  """

  use GenServer

  @behaviour Cluster.Strategy

  alias Cluster.Strategy.State

  require Logger

  @default_poll_interval 5_000
  @default_node_ttl 15_000

  @heartbeat_sql """
  INSERT INTO cluster_nodes (node, role, updated_at) VALUES ($1, $2, now())
  ON CONFLICT (node) DO UPDATE SET role = EXCLUDED.role, updated_at = now()
  """

  @discover_sql """
  SELECT node FROM cluster_nodes
  WHERE updated_at > now() - ($1 || ' milliseconds')::interval AND node <> $2
  """

  @impl Cluster.Strategy
  @spec start_link([State.t()]) :: {:ok, pid} | :ignore | {:error, term}
  def start_link([%State{} = state]) do
    GenServer.start_link(__MODULE__, state)
  end

  @impl GenServer
  @spec init(State.t()) :: {:ok, State.t()}
  def init(%State{} = state) do
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl GenServer
  @spec handle_info(:reconcile, State.t()) :: {:noreply, State.t()}
  def handle_info(:reconcile, %State{} = state) do
    reconcile(state)
    Process.send_after(self(), :reconcile, poll_interval(state))
    {:noreply, state}
  end

  @spec reconcile(State.t()) :: :ok
  defp reconcile(%State{} = state) do
    if Node.alive?() do
      heartbeat()
      state |> discover_peers() |> connect(state)
    end

    :ok
  end

  @spec heartbeat :: :ok
  defp heartbeat do
    role = Atom.to_string(Hyper.Cfg.Role.get())

    _ =
      Ecto.Adapters.SQL.query!(
        Hyper.Img.Db.Repo,
        @heartbeat_sql,
        [Atom.to_string(Node.self()), role]
      )

    :ok
  rescue
    error ->
      Logger.warning("cluster_nodes heartbeat failed: #{inspect(error)}")
      :ok
  end

  @spec discover_peers(State.t()) :: [node]
  defp discover_peers(%State{} = state) do
    ttl_ms = Integer.to_string(node_ttl(state))
    self_name = Atom.to_string(Node.self())

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(Hyper.Img.Db.Repo, @discover_sql, [ttl_ms, self_name])

    Enum.map(rows, fn [name] -> String.to_atom(name) end)
  rescue
    error ->
      Logger.warning("cluster_nodes discovery failed: #{inspect(error)}")
      []
  end

  @spec connect([node], State.t()) :: :ok
  defp connect([], %State{}), do: :ok

  defp connect(peers, %State{} = state) do
    _ =
      Cluster.Strategy.connect_nodes(
        state.topology,
        state.connect,
        state.list_nodes,
        peers
      )

    :ok
  end

  @spec poll_interval(State.t()) :: pos_integer
  defp poll_interval(%State{config: config}) do
    Keyword.get(config, :poll_interval, @default_poll_interval)
  end

  @spec node_ttl(State.t()) :: pos_integer
  defp node_ttl(%State{config: config}) do
    Keyword.get(config, :node_ttl, @default_node_ttl)
  end
end
