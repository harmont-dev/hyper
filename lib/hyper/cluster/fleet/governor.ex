defmodule Hyper.Cluster.Fleet.Governor do
  @moduledoc """
  The cluster singleton that decides *how many* machines exist.

  One controller per machine is `Hyper.Cluster.Fleet.Machine`'s job; deciding
  that a machine should exist at all is this module's, and nothing else in Fleet
  is allowed to hold that opinion. The split is deliberate and total:

    * `Hyper.Cluster.Fleet.Policy` computes the decision. It is pure, so the part
      that costs real money can be proved rather than watched.
    * this module supplies the observations, applies the operator's rate limits,
      and carries out **at most one** action per tick.
    * the controller it starts owns everything about that machine afterwards —
      provisioning, deadlines, backoff, cordon, drain, destroy. The Governor
      never calls a provider's `create/2` or `destroy/2` itself and cannot
      destroy a machine at all; the strongest thing it can say is "please
      drain", which the controller may take a long time to honour and which
      `Hyper.Cluster.Fleet.Machine.uncordon/1` can still revoke.

  ## Election

  Every node runs a Governor; exactly one regulates. The winner is whoever holds
  `{:singleton, :fleet_governor}` in `Hyper.Cluster.Routing`, contended for the
  same way `Hyper.Img.Db.Gc` contends for its key: a standby re-tries on each
  tick and does nothing else until it wins. Because the key is held by the pid,
  losing the node that holds it frees it, and the next standby tick picks it up.

  Registering is not the same as having won. `Horde.Registry.register/3` consults
  the *local* replica and then writes to the CRDT, so two nodes booting inside
  one sync window both succeed — the same race
  `Hyper.Cluster.Routing.register_self/1` exists for. Horde resolves it later by
  killing the loser, but "later" is long enough to have ordered a machine each.
  So a Governor promotes itself only once a `lookup/2` shows *its own pid*
  holding the key, which is one tick after it registered. Election costs an extra
  tick and cannot double-order; nothing about a fleet needs to be regulated
  within fifteen seconds of a boot.

  ## Regulating requires being able to see

  `Hyper.Cluster.Budget` is a CRDT replica, and an empty one is indistinguishable
  from an empty cluster: at boot this node's own `Hyper.Node.Budget.Advertiser`
  has not published yet (`Hyper.Cluster` starts before `Hyper.Node`), and a
  registration is not visible to the process that made it until the diff loop
  has run. Regulating against that reads as "there is no capacity anywhere" and
  buys a machine the cluster already has. Two checks stand in for "this replica
  has converged", and a machine has to pass both:

    * **It can see itself.** A host advertises, so its own absence means the
      replica has not caught up. A `:control` node (`Hyper.Cfg.Node`) never
      advertises at all, so this check does not apply to it — gating on it would
      leave the very machine that provisions the fleet permanently unable to.
    * **It can see what it knows joined.** Every machine whose controller reached
      `:ready` watched that node join; if the replica no longer lists one, the
      replica is stale. This is the only check a control node has, and an empty
      fleet passes it trivially — which is what lets a cluster bootstrap from
      nothing.

  Adoption is not gated by either: it is idempotent, it is keyed on the
  provider's listing rather than on the replica, and rebuilding the controllers
  as early as possible is the whole point of it.

  ## One tick

    1. **List.** `Provider.list/1` is the fleet's ground truth. A provider API
       outage answers `{:error, _}`, and the tick then does *nothing* — it does
       not adopt, does not regulate, and above all does not read an empty or
       partial list as machines having disappeared. Fleet's destructive path is
       reached only by a controller draining its own machine, so a provider that
       is merely unreachable can never cost the operator a host.
    2. **Adopt.** Ensure a controller exists for every listed machine. Existence
       is asked of the `{:machine, id}` key in `Hyper.Cluster.Routing`, so a
       controller already running on *another* node counts and is not
       duplicated. Missing ones are started under
       `Hyper.Cluster.Fleet.Supervisor` with `{:adopt, info}`. This is the step
       that rebuilds the world: a Governor that crashed, migrated, or has never
       run before reaches the same state on its next tick, because the machines
       are the truth and the controllers are derived from them.
    3. **Regulate.** `Policy.decide/3` over `Hyper.Cluster.Budget.all_states/0`
       and the number of machines ordered but not yet joined, then one action:
       start a controller with `{:create, tags}`, or ask one controller to drain.

  Adoption and regulation are ordered, not independent: a machine that exists
  without a controller is invisible to `Policy` (its node contributes headroom
  through `Hyper.Cluster.Budget` but it would not count as in-flight), so
  adopting first is what stops a restarted Governor from buying a second machine
  for a shortage that is already being answered.

  ## What the Governor refuses to do

  **Two machines at once.** `@max_in_flight` is 1, and it is not a tuning knob.
  It is the direct expression of the design the fleet is regulated by: grow by
  one, watch it join, re-evaluate. Capacity that has been ordered has not been
  measured, and ordering against the same unanswered shortage twice is the
  classic way an autoscaler turns a small shortage into a large bill.

  **Anything at all during a cooldown.** `cooldown` bounds the time between two
  size changes in either direction, so the fleet reacts to a machine having
  joined (or left) rather than to the same reading twice.

  **Growth a provider cannot deliver.** With `capabilities/1` lacking `:create`
  — the default `Hyper.Cluster.Fleet.Provider.Static` among them — the shortage
  is reported once and then never again. An observe-only fleet is a supported
  deployment, not a fault, and it must not produce a log line every tick
  forever.

  **Reclaiming a machine an operator parked.** When growth is wanted and a
  machine is already `:draining`, that machine is un-cordoned instead of a new
  one being bought: it is paid for and already joined, so it is strictly the
  better answer. A machine sitting in `:cordoned` is left alone — that is the
  manual "drain before a kernel upgrade" state, and taking it back would be
  Fleet overruling the operator.

  ## Crash safety

  Losing this process loses no state. `last_change` (the cooldown clock) and the
  once-only capability warning are the only things it holds, and both are
  advisory: a restarted Governor re-lists, re-adopts every machine, and at worst
  acts one cooldown early. There is nothing here worth persisting, which is why
  a plain `GenServer` on every node beats a single migrating one.

  Configuration is loaded the same way, and for the same reason it is never
  fatal: a Governor whose `Hyper.Cfg.Fleet` will not load logs and stays inert,
  retrying on each tick. It is a child of `Hyper.Cluster`, so stopping over a
  mistyped autoscaling knob would fail `Hyper.Application` and take a
  Firecracker host offline — a machine that runs VMs perfectly well without ever
  regulating a fleet.
  """

  use GenServer

  require Logger

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Fleet.Machine
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Fleet.Policy
  alias Hyper.Cluster.Fleet.Provider
  alias Hyper.Cluster.Fleet.Supervisor, as: Controllers
  alias Hyper.Cluster.Routing
  alias Hyper.Node.Budget.NodeState
  alias Unit.Time

  @singleton_key {:singleton, :fleet_governor}
  @supervisor Hyper.Cluster.Fleet.Supervisor

  # Slow enough that a tick is cheap next to a provider's rate limit, fast enough
  # that a shortage is answered well inside a machine's boot time.
  @tick Time.s(15)

  # A controller on a wedged node must not wedge the regulator with it.
  @describe_timeout Time.s(5)

  # See the moduledoc: one machine in flight, always.
  @max_in_flight 1

  # Ordered but not yet joined. These are the phases `Hyper.Cluster.Budget` knows
  # nothing about, which is exactly why `Policy.decide/3` has to be told the count.
  @unjoined [:requested, :provisioning, :failed, :awaiting_join]

  @typedoc """
  `cfg` and `provider_state` are both built lazily and kept: configuration that
  will not load, and a provider whose `init/1` fails, are retried on the next
  tick rather than crashing the regulator. `warned` remembers which permanent
  conditions have already been reported, so a fleet nobody can grow does not
  narrate that fact every fifteen seconds.
  """
  @type t :: %__MODULE__{
          cfg: Config.t() | nil,
          supervisor: atom(),
          provider_state: Provider.state() | nil,
          last_change: integer() | nil,
          role: :active | :standby,
          warned: MapSet.t(atom())
        }

  @enforce_keys [:supervisor]
  defstruct [
    :cfg,
    :supervisor,
    :provider_state,
    :last_change,
    role: :standby,
    warned: MapSet.new()
  ]

  @doc """
  Start the node's Governor.

  Options are `:cfg` (a `t:Hyper.Cfg.Fleet.t/0`; loaded if absent) and
  `:supervisor` (the `Horde.DynamicSupervisor` controllers are started under,
  `Hyper.Cluster.Fleet.Supervisor` by default).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "This node's role and when it last changed the fleet's size, for introspection."
  @spec status() :: %{role: :active | :standby, last_change: integer() | nil}
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      cfg: Keyword.get(opts, :cfg),
      supervisor: Keyword.get(opts, :supervisor, @supervisor)
    }

    {:ok, state, {:continue, :tick}}
  end

  @impl true
  def handle_continue(:tick, state), do: {:noreply, run(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{role: state.role, last_change: state.last_change}, state}
  end

  @impl true
  def handle_info(:tick, state), do: {:noreply, run(state)}

  # Monitor noise and timers left over from an earlier role must never take the
  # regulator down: a restart would only re-derive the same state, slower.
  def handle_info(_msg, state), do: {:noreply, state}

  @spec run(t()) :: t()
  defp run(state) do
    state = tick(state)
    _ = Process.send_after(self(), :tick, Time.as_ms(@tick))
    state
  end

  @doc false
  # One regulation cycle, driven directly by the tests: everything below this
  # point is a function of the arguments and the cluster, never of a timer.
  @spec tick(t()) :: t()
  def tick(state) do
    case elect(state) do
      %__MODULE__{role: :active} = active -> reconcile(active)
      standby -> standby
    end
  end

  # Only a standby contends. Re-registering a key this process already holds
  # would answer `:already_registered` — against ourselves — and demote us.
  @spec elect(t()) :: t()
  defp elect(%__MODULE__{role: :active} = state), do: state

  defp elect(state) do
    case Horde.Registry.lookup(Routing.name(), @singleton_key) do
      [{pid, _value}] when pid == self() -> promote(state)
      [{_other, _value}] -> state
      [] -> contend(state)
    end
  end

  # A successful registration is a claim, not a win: the replica this answer came
  # from is the local one, and a peer that registered inside the same sync window
  # got the same answer. Promotion waits for the next tick to see the key
  # resolved, by which point Horde has killed whichever contender lost.
  @spec contend(t()) :: t()
  defp contend(state) do
    case Horde.Registry.register(Routing.name(), @singleton_key, nil) do
      {:ok, _pid} -> state
      {:error, {:already_registered, pid}} when pid == self() -> promote(state)
      {:error, {:already_registered, _pid}} -> state
    end
  end

  @spec promote(t()) :: t()
  defp promote(state) do
    Logger.info("fleet governor: this node is now the active regulator")
    %{state | role: :active}
  end

  @spec reconcile(t()) :: t()
  defp reconcile(state) do
    with {:ok, configured} <- ensure_config(state),
         {:ok, ready} <- ensure_provider(configured) do
      observe(ready)
    else
      {:error, _reason, state} -> state
    end
  end

  # Inert rather than dead: see the moduledoc. The warning is once-only because
  # a configuration file does not fix itself between two ticks.
  @spec ensure_config(t()) :: {:ok, t()} | {:error, term(), t()}
  defp ensure_config(%__MODULE__{cfg: nil} = state) do
    case Config.load() do
      {:ok, cfg} ->
        {:ok, %{state | cfg: cfg}}

      {:error, reason} ->
        {:error, reason, warn_once(state, :config, "fleet configuration: #{inspect(reason)}")}
    end
  end

  defp ensure_config(state), do: {:ok, state}

  @spec ensure_provider(t()) :: {:ok, t()} | {:error, term(), t()}
  defp ensure_provider(%__MODULE__{provider_state: nil} = state) do
    case state.cfg.provider.init(state.cfg.provider_opts) do
      {:ok, provider_state} ->
        {:ok,
         %{state | provider_state: provider_state, warned: MapSet.delete(state.warned, :create)}}

      {:error, reason} ->
        Logger.error(
          "fleet governor: provider #{inspect(state.cfg.provider)} could not be " <>
            "initialised (#{inspect(reason)}); regulating nothing this tick"
        )

        {:error, reason, state}
    end
  end

  defp ensure_provider(state), do: {:ok, state}

  # A fleet we cannot see is not a fleet that has gone away. Skipping the whole
  # tick (rather than regulating against a partial list) is what keeps a provider
  # outage from being expressed as machine churn.
  @spec observe(t()) :: t()
  defp observe(state) do
    case state.cfg.provider.list(state.provider_state) do
      {:ok, infos} ->
        {state, adopting} = adopt(state, infos)
        regulate(state, adopting)

      {:error, reason} ->
        Logger.warning(
          "fleet governor: provider #{inspect(state.cfg.provider)} could not list " <>
            "machines (#{inspect(reason)}); skipping this tick"
        )

        state
    end
  end

  # Answers with the number of controllers this tick *started*, because those are
  # invisible to the registry read `regulate/2` makes moments later (a Horde
  # registration reaches the local replica through the diff loop, not through the
  # call that made it) and a machine already being adopted is a machine already
  # answering the shortage.
  @spec adopt(t(), [Info.t()]) :: {t(), non_neg_integer()}
  defp adopt(state, infos) do
    infos = report_duplicates(infos)
    {state, Enum.count(infos, &(adopt_one(state, &1) == :started))}
  end

  # Two machines under one Fleet id can only be a bug: an id is either the
  # provider's own (unique by construction) or a claim minted per controller. It
  # happens when a `create/2` whose answer was lost is retried and both attempts
  # took effect — and the second machine would otherwise be adopted by nobody,
  # cordoned by nobody and destroyed by nobody while being billed forever.
  @spec report_duplicates([Info.t()]) :: [Info.t()]
  defp report_duplicates(infos) do
    duplicated =
      infos
      |> Enum.group_by(&Machine.key/1)
      |> Enum.reject(&match?({_id, [_only]}, &1))

    _ = Enum.each(duplicated, &report_duplicate/1)
    infos
  end

  @spec report_duplicate({Machine.id(), [Info.t()]}) :: :ok
  defp report_duplicate({id, several}) do
    Logger.error(
      "fleet governor: #{length(several)} machines share the fleet id #{id} " <>
        "(#{Enum.map_join(several, ", ", & &1.id)}); only one of them can be controlled — " <>
        "the rest are unmanaged and have to be retired by hand"
    )
  end

  # The registry key is the whole existence test, and it is cluster-wide: a
  # machine whose controller runs on another node is already adopted. The lookup
  # can also be lost to a race with another Governor mid-handover, which is why
  # the controller re-checks the same key from its own `init` and refuses to be
  # the second one.
  @spec adopt_one(t(), Info.t()) :: :started | :ok | :error
  defp adopt_one(state, info) do
    case controller(Machine.key(info)) do
      nil -> started(start_controller(state, {:adopt, info}))
      pid when is_pid(pid) -> :ok
    end
  end

  @spec started(:ok | :error) :: :started | :error
  defp started(:ok), do: :started
  defp started(:error), do: :error

  @spec controller(Machine.id()) :: pid() | nil
  defp controller(id) do
    case Horde.Registry.lookup(Routing.name(), {:machine, id}) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @spec regulate(t(), non_neg_integer()) :: t()
  defp regulate(state, adopting) do
    states = Budget.all_states()
    machines = controllers()

    if measurable?(states, machines) do
      decide(state, states, machines, adopting)
    else
      warn_once(
        state,
        :blind,
        "the budget registry does not yet show what this node knows to be joined, " <>
          "so the cluster cannot be measured; adopting machines but regulating nothing"
      )
    end
  end

  # Is the replica worth deciding on? Two independent reasons it might not be,
  # and a `:control` node has only the second (see `Hyper.Cfg.Node`): it never
  # advertises, so its own absence says nothing at all and gating on it would
  # leave the machine that provisions the fleet permanently unable to.
  @spec measurable?([NodeState.t()], [Machine.summary()]) :: boolean()
  defp measurable?(states, machines),
    do: self_visible?(states) and joined_visible?(states, machines)

  # A host advertises itself, so its own absence means the replica has not
  # converged rather than that the cluster is empty. See the moduledoc.
  @spec self_visible?([NodeState.t()]) :: boolean()
  defp self_visible?(states) do
    Hyper.Cfg.Node.control?() or Enum.any?(states, &(&1.node == node()))
  end

  # The role-independent half, and the only check a control node has: a `:ready`
  # controller watched its machine join, so that machine missing from the replica
  # means the replica is stale. It is briefly true for real when a host dies —
  # the controller has not processed `nodedown` yet — and refusing to regulate
  # for those few seconds is the safe direction to be wrong in. An empty fleet
  # trivially passes, which is what lets a cluster bootstrap from nothing.
  @spec joined_visible?([NodeState.t()], [Machine.summary()]) :: boolean()
  defp joined_visible?(states, machines) do
    advertised = MapSet.new(states, & &1.node)
    Enum.all?(nodes(machines, :ready), &MapSet.member?(advertised, &1))
  end

  @spec decide(t(), [NodeState.t()], [Machine.summary()], non_neg_integer()) :: t()
  defp decide(state, states, machines, adopting) do
    in_flight = Enum.count(machines, &(&1.phase in @unjoined)) + adopting

    case Policy.decide(states, in_flight, state.cfg, control(machines)) do
      {:grow, 1} -> grow(state, machines, in_flight)
      {:shrink, node} -> shrink(state, machines, node)
      :hold -> state
    end
  end

  # What the policy is allowed to name. A node with no `:ready` controller of
  # ours is not ours to drain, and saying so here — rather than discovering it
  # after the decision — is what stops the emptiest unmanaged node in the cluster
  # from being proposed, refused and re-proposed forever.
  @spec control([Machine.summary()]) :: Policy.control()
  defp control(machines) do
    %{drainable: nodes(machines, :ready), draining: nodes(machines, :draining)}
  end

  @spec nodes([Machine.summary()], Machine.phase()) :: [node()]
  defp nodes(machines, phase) do
    for %{phase: ^phase, node: node} <- machines, not is_nil(node), do: node
  end

  # Concurrently, because `@describe_timeout` is meant to bound the *tick*: a
  # dozen controllers stranded on a partitioned node would otherwise add their
  # timeouts up into a regulation period longer than the tick interval, exactly
  # when regulation matters most.
  @spec controllers() :: [Machine.summary()]
  defp controllers do
    Routing.name()
    |> Horde.Registry.select([{{{:machine, :"$1"}, :"$2", :_}, [], [:"$2"]}])
    |> Task.async_stream(&describe/1,
      timeout: Time.as_ms(@describe_timeout),
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.flat_map(fn
      {:ok, summaries} -> summaries
      {:exit, _reason} -> []
    end)
  end

  # A controller that died or migrated between the select and the call is not an
  # error to report, it is a fleet the next tick will see differently.
  @spec describe(pid()) :: [Machine.summary()]
  defp describe(pid) do
    [:gen_statem.call(pid, :describe, Time.as_ms(@describe_timeout))]
  catch
    :exit, _reason -> []
  end

  @spec grow(t(), [Machine.summary()], non_neg_integer()) :: t()
  defp grow(state, machines, in_flight) do
    if cooling_down?(state) do
      state
    else
      case reclaimable(machines) do
        nil -> provision(state, in_flight)
        machine -> reclaim(state, machine)
      end
    end
  end

  # Deterministic so two Governors mid-handover would make the same choice.
  @spec reclaimable([Machine.summary()]) :: Machine.summary() | nil
  defp reclaimable(machines) do
    machines
    |> Enum.filter(&(&1.phase == :draining))
    |> Enum.sort_by(& &1.id)
    |> List.first()
  end

  @spec reclaim(t(), Machine.summary()) :: t()
  defp reclaim(state, machine) do
    case ask(machine.id, &Machine.uncordon/1) do
      :ok ->
        Logger.info(
          "fleet governor: reclaimed draining machine #{machine.id} instead of " <>
            "provisioning a new one"
        )

        changed(state)

      {:error, reason} ->
        Logger.warning(
          "fleet governor: could not reclaim #{machine.id} (#{inspect(reason)}); " <>
            "retrying next tick"
        )

        state
    end
  end

  # Once per provider state, not once per tick: an observe-only fleet is the
  # default deployment and its shortages are permanent by definition.
  @spec provision(t(), non_neg_integer()) :: t()
  defp provision(state, in_flight) do
    cond do
      not creates?(state) -> warn_once(state, :create, shortage(state))
      in_flight >= @max_in_flight -> state
      true -> order(state)
    end
  end

  @spec shortage(t()) :: String.t()
  defp shortage(state) do
    "the cluster wants more capacity but #{inspect(state.cfg.provider)} cannot create " <>
      "machines; leaving the fleet as it is"
  end

  @spec creates?(t()) :: boolean()
  defp creates?(state) do
    Provider.supports?(state.cfg.provider, state.provider_state, :create)
  end

  # No tags of our own: identifying tags are the provider's deployment
  # configuration (it is the provider that must be able to find its machines
  # again in `list/1`), and the controller mints its own claim tag on top.
  @spec order(t()) :: t()
  defp order(state) do
    case start_controller(state, {:create, %{}}) do
      :ok -> changed(state)
      :error -> state
    end
  end

  @spec shrink(t(), [Machine.summary()], node()) :: t()
  defp shrink(state, machines, node) do
    if cooling_down?(state) do
      state
    else
      case ready_on(machines, node) do
        nil ->
          # `Policy` is told which nodes are drainable, so it should never name
          # one that is not; if it does, the controller moved out of `:ready`
          # between the two reads. Left as a refusal rather than a fallback
          # because draining a machine the policy did not weigh is exactly the
          # decision this module is not allowed to take.
          Logger.warning(
            "fleet governor: #{node} was proposed for draining but no ready " <>
              "controller owns it; leaving the fleet as it is"
          )

          state

        machine ->
          drain(state, machine)
      end
    end
  end

  @spec ready_on([Machine.summary()], node()) :: Machine.summary() | nil
  defp ready_on(machines, node) do
    Enum.find(machines, &(&1.node == node and &1.phase == :ready))
  end

  @spec drain(t(), Machine.summary()) :: t()
  defp drain(state, machine) do
    case ask(machine.id, &Machine.drain/1) do
      :ok ->
        Logger.info("fleet governor: draining #{machine.node} (machine #{machine.id})")
        changed(state)

      {:error, reason} ->
        Logger.warning(
          "fleet governor: could not drain #{machine.id} (#{inspect(reason)}); " <>
            "retrying next tick"
        )

        state
    end
  end

  # Delegated rather than re-implemented: which `start_child/2` answers count as
  # success (`:ignore` above all — see `Hyper.Cluster.Fleet.Supervisor`) is one
  # rule, and two copies of it would eventually disagree about whether a
  # duplicate start worked.
  @spec start_controller(t(), Machine.entry()) :: :ok | :error
  defp start_controller(state, entry) do
    case Controllers.start_machine(state.cfg, entry, state.supervisor) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "fleet governor: could not start a controller (#{inspect(reason)}); " <>
            "retrying next tick"
        )

        :error
    end
  end

  # A controller is a remote process that may be shutting down as we call it;
  # that is a fleet that moved, not a Governor that should crash.
  @spec ask(Machine.id(), (Machine.id() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  defp ask(id, fun) do
    fun.(id)
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @spec cooling_down?(t()) :: boolean()
  defp cooling_down?(%__MODULE__{last_change: nil}), do: false

  defp cooling_down?(%__MODULE__{last_change: at} = state) do
    System.monotonic_time(:millisecond) - at < Time.as_ms(state.cfg.cooldown)
  end

  @spec changed(t()) :: t()
  defp changed(state), do: %{state | last_change: System.monotonic_time(:millisecond)}

  @doc false
  # Whether `reason` has already been reported by this Governor.
  @spec warned?(t(), atom()) :: boolean()
  def warned?(%__MODULE__{} = state, reason), do: MapSet.member?(state.warned, reason)

  # Conditions that persist by nature — an observe-only provider, a
  # configuration file that will not parse, a replica this node is not in yet —
  # are reported on the tick that first meets them and then not again. A tick is
  # fifteen seconds; anything reported every tick is noise nobody reads.
  @spec warn_once(t(), atom(), String.t()) :: t()
  defp warn_once(state, reason, message) do
    if warned?(state, reason) do
      state
    else
      Logger.warning("fleet governor: " <> message)
      %{state | warned: MapSet.put(state.warned, reason)}
    end
  end
end
