defmodule Hyper.Cluster.Fleet.Strategy do
  @moduledoc """
  A [libcluster](https://github.com/bitwalker/libcluster) strategy that forms the
  BEAM cluster out of the fleet: it polls
  `c:Hyper.Cluster.Fleet.Provider.list/1` and connects to the node names the
  provider reports.

  This closes the join gap. `Hyper.Cfg.Cluster` defaults to no topology at all,
  so a machine Fleet provisions at runtime has no way *into* the cluster — and
  until it is in the cluster it is invisible to `Hyper.Cluster.Budget`, which is
  the only readiness signal Fleet has. Making the provider's inventory the
  membership source closes that loop without inventing a second source of truth:
  the same `list/1` that tells `Hyper.Cluster.Fleet.Governor` which machines
  exist tells distribution which nodes to dial.

  ## Configuration

      config :hyper, Hyper.Cfg.Cluster,
        topologies: [fleet: [strategy: Hyper.Cluster.Fleet.Strategy]]

  Everything in the topology's `config:` is optional:

    * `:provider` and `:provider_opts` — override the provider. The default is
      whatever `Hyper.Cfg.Fleet` names, which is almost always what you want: the
      fleet Hyper regulates and the fleet Hyper clusters with should not be two
      different sets of machines.
    * `:polling_interval` — a `t:Unit.Time.t/0` (a plain millisecond integer is
      also accepted, that being libcluster's own convention). Defaults to 10 s.

  ## What the provider must have arranged first

  Connecting is all this strategy does, and connecting only succeeds against a
  machine that is already a *speakable* BEAM node: release running, distribution
  up, node named exactly as `list/1` reports it, and — the one that bites — the
  same Erlang cookie. None of that can be arranged from here; by the time Hyper
  could talk to the machine to configure it, it would already be clustered. It is
  the provider's user-data / cloud-init that has to bake in the cookie and
  Hyper's configuration. A machine that boots without them is never connected: it
  stays `:pending`, and its controller writes it off at `Hyper.Cfg.Fleet`'s
  `provision_deadline` and replaces it.

  ## It only ever connects

  libcluster's polling strategies also disconnect nodes that have dropped out of
  their source of truth. This one deliberately does not. A node vanishing from
  `list/1` is not evidence that the node is gone: a provider API blip, a
  half-returned page, and a machine mid-`:draining` — still running VMs, still
  needed in `Hyper.Cluster.Routing` — are indistinguishable from here.
  Disconnecting on that signal would tear a live node's VMs out of the routing
  registry and its capacity out of `Hyper.Cluster.Budget` while both are still
  real, and Horde would then try to redistribute what it could. Machines leave
  the cluster the way they are meant to: their controller destroys them and
  distribution notices.

  ## Ordering

  Started by `Cluster.Supervisor` from `Hyper.Application`, which runs *before*
  `Hyper.Cluster`. It can read no Horde registry and nothing else the node has
  not booted yet, which is why it asks the provider itself rather than asking the
  Governor what the fleet looks like.
  """

  use GenServer
  use Cluster.Strategy

  alias Cluster.Strategy
  alias Cluster.Strategy.State
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Fleet.Provider
  alias Unit.Time

  require Logger

  @default_poll Time.s(10)

  @typedoc """
  The resolved provider, carried in the strategy state's `meta`.

  Built once at start: `c:Hyper.Cluster.Fleet.Provider.init/1` is cheap by
  contract, but not free, and a poll every ten seconds is not the place to
  re-open a client.
  """
  @type meta :: %{provider: module(), provider_state: Provider.state()}

  @impl Cluster.Strategy
  @spec start_link([State.t()]) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link([%State{} = state]), do: GenServer.start_link(__MODULE__, [state])

  @impl GenServer
  def init([%State{} = state]) do
    case resolve(state) do
      {:ok, meta} ->
        {:ok, poll(%State{state | meta: meta})}

      {:error, reason} ->
        Logger.warning(
          "fleet strategy: no provider to poll (#{inspect(reason)}); this node will not " <>
            "cluster with the fleet"
        )

        :ignore
    end
  end

  @impl GenServer
  def handle_info(:poll, state), do: {:noreply, poll(state)}

  # A stray poll from an earlier incarnation, or monitor noise: never take the
  # strategy down over it. The next poll re-derives the whole answer anyway.
  def handle_info(_msg, state), do: {:noreply, state}

  @spec poll(State.t()) :: State.t()
  defp poll(state) do
    :ok = reconcile(state)
    _ = Process.send_after(self(), :poll, poll_interval(state))
    state
  end

  @spec reconcile(State.t()) :: :ok
  defp reconcile(%State{meta: meta} = state) do
    case meta.provider.list(meta.provider_state) do
      {:ok, infos} -> connect(state, dialable(infos))
      {:error, reason} -> list_failed(state, reason)
    end
  end

  # `connect_nodes/4` skips what is already connected and logs each failure
  # itself, so there is nothing left to do with its return value: a machine that
  # has not finished booting is the normal case here, not an error, and the next
  # poll retries it.
  @spec connect(State.t(), [node()]) :: :ok
  defp connect(%State{} = state, nodes) do
    _ = Strategy.connect_nodes(state.topology, state.connect, state.list_nodes, nodes)
    :ok
  end

  @spec list_failed(State.t(), term()) :: :ok
  defp list_failed(%State{topology: topology}, reason) do
    Logger.warning(
      "fleet strategy (#{topology}): provider list failed (#{inspect(reason)}); keeping the " <>
        "current cluster and retrying"
    )
  end

  # Every machine that could plausibly answer distribution: it has a node name,
  # and the provider has not declared it gone. `:pending` machines are included
  # on purpose — a node answers distribution as soon as its release is up, which
  # is routinely before the vendor flips its status, and connecting early is
  # precisely how the machine becomes visible in `Hyper.Cluster.Budget`.
  @spec dialable([Info.t()]) :: [node()]
  defp dialable(infos) do
    for %Info{node: node, status: status} <- infos, not is_nil(node), status != :gone, do: node
  end

  @spec resolve(State.t()) :: {:ok, meta()} | {:error, term()}
  defp resolve(%State{config: config}) do
    with {:ok, provider, opts} <- configured(config),
         {:ok, provider_state} <- provider.init(opts) do
      {:ok, %{provider: provider, provider_state: provider_state}}
    end
  end

  # A topology may name its own provider — the seam tests drive this through, and
  # an escape hatch for a deployment whose membership source is not the fleet it
  # regulates. Otherwise the fleet's own configuration is the answer.
  @spec configured(keyword()) :: {:ok, module(), keyword()} | {:error, term()}
  defp configured(config) do
    case Keyword.fetch(config, :provider) do
      {:ok, provider} -> {:ok, provider, Keyword.get(config, :provider_opts, [])}
      :error -> from_fleet_config()
    end
  end

  @spec from_fleet_config() :: {:ok, module(), keyword()} | {:error, term()}
  defp from_fleet_config do
    case Hyper.Cfg.Fleet.load() do
      {:ok, cfg} -> {:ok, cfg.provider, cfg.provider_opts}
      {:error, _reason} = err -> err
    end
  end

  # libcluster's own strategies take a plain millisecond integer while `Unit.Time`
  # is the house style; accept either, so a topology copied out of libcluster's
  # documentation still works.
  @spec poll_interval(State.t()) :: integer()
  defp poll_interval(%State{config: config}) do
    case Keyword.get(config, :polling_interval, @default_poll) do
      ms when is_integer(ms) and ms > 0 -> ms
      interval -> Time.as_ms(interval)
    end
  end
end
