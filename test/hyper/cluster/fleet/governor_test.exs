defmodule Hyper.Cluster.Fleet.GovernorTest do
  @moduledoc """
  The Governor's contracts, driven one tick at a time rather than by waiting on
  its timer:

    * a provider that cannot be listed — or cannot be *built* — changes nothing
      at all: no controller is started, no machine is destroyed, no cooldown is
      spent, the tick does not crash, and the next one retries;
    * a machine that already has a controller (anywhere in the cluster) is never
      given a second one, and adopting the same list twice is a no-op;
    * growth is gated: once by `cooldown`, once by the one-machine-at-a-time
      rule, and refused outright by a provider that cannot create;
    * a wanted machine is answered by reclaiming a *draining* controller in
      preference to buying one — but a machine parked in `:cordoned` by an
      operator is left alone;
    * **scale-in only ever names a machine this Governor owns a `:ready`
      controller for.** This is the one destructive path in the feature, so it
      is driven for every combination of "who owns the emptiest node";
    * a controller that cannot answer — crashed, or wedged on a partitioned node
      — is skipped rather than taking the regulation tick down with it;
    * a Governor regulates only once it can see its own node in the budget
      replica, and only once the registry has confirmed its claim on the
      singleton key; a standby does nothing whatsoever, not even ask the
      provider;
    * configuration that will not load leaves it inert, never dead: it is a
      child of `Hyper.Cluster`, and a typo in an autoscaling knob must not stop
      a Firecracker host from booting.

  Both real `Hyper.Cluster.Fleet.Machine` controllers (for the adoption path,
  which is only meaningful end to end) and stub controllers registered under the
  same `{:machine, id}` key (for phases a real controller would take minutes to
  reach) are used.
  """

  use ExUnit.Case, async: false

  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Fleet.Governor
  alias Hyper.Cluster.Fleet.Machine
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Routing
  alias Hyper.Node.Budget.NodeState
  alias Unit.Bandwidth
  alias Unit.Information
  alias Unit.Time

  @singleton_key {:singleton, :fleet_governor}

  # A supervisor that was never started: `start_child/2` against it exits, so a
  # tick that completes is a tick that never tried to start a controller.
  @absent_supervisor %{supervisor: :fleet_sup_never_started}

  defmodule StubProvider do
    @moduledoc """
    A provider whose answers are its options, and which reports every mutation it
    is asked for to `owner`. `list:` is either a list of `Info`s or an
    `{:error, _}`.
    """

    @behaviour Hyper.Cluster.Fleet.Provider

    alias Hyper.Cluster.Fleet.Machine
    alias Hyper.Cluster.Fleet.Machine.Info

    @impl true
    def init(opts) do
      send(Keyword.fetch!(opts, :owner), :provider_init)

      case Keyword.get(opts, :init, :ok) do
        :ok -> {:ok, Map.new(opts)}
        {:error, _reason} = err -> err
      end
    end

    @impl true
    def capabilities(state), do: Map.fetch!(state, :capabilities)

    @impl true
    def list(state) do
      case Map.fetch!(state, :list) do
        {:error, _reason} = err -> err
        infos when is_list(infos) -> {:ok, infos}
      end
    end

    @impl true
    def create(state, tags) do
      send(state.owner, {:create, tags})
      {:ok, %Info{id: Map.fetch!(tags, Machine.claim_tag()), status: :pending, tags: tags}}
    end

    @impl true
    def destroy(state, id) do
      send(state.owner, {:destroy, id})
      :ok
    end
  end

  defmodule StubController do
    @moduledoc """
    Stands in for a `Hyper.Cluster.Fleet.Machine` in a chosen phase: it claims the
    same `{:machine, id}` identity, answers `:describe` with the summary it was
    given, and reports every other call to `owner` instead of acting on it.
    """

    use GenServer

    alias Hyper.Cluster.Routing

    @spec start_link({map(), pid()}) :: GenServer.on_start()
    def start_link({summary, owner}), do: GenServer.start_link(__MODULE__, {summary, owner})

    @impl true
    def init({summary, owner}) do
      case Routing.register_self({:machine, summary.id}) do
        :ok -> {:ok, {summary, owner}}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl true
    def handle_call(:describe, _from, {summary, owner}), do: {:reply, summary, {summary, owner}}

    def handle_call(event, _from, {summary, owner}) do
      send(owner, {:called, event, summary.id})
      {:reply, :ok, {summary, owner}}
    end
  end

  defmodule MuteController do
    @moduledoc """
    A controller that cannot describe itself: `:crash` dies when asked, `:wedge`
    never answers. Both are what a controller on a partitioned or dying node
    looks like from the Governor, and neither may stop the fleet being regulated.
    """

    use GenServer

    alias Hyper.Cluster.Routing

    @spec start_link({String.t(), :crash | :wedge}) :: GenServer.on_start()
    def start_link({id, how}), do: GenServer.start_link(__MODULE__, {id, how})

    @impl true
    def init({id, how}) do
      case Routing.register_self({:machine, id}) do
        :ok -> {:ok, how}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl true
    def handle_call(:describe, _from, :crash), do: {:stop, :describing_is_fatal, :crash}
    def handle_call(:describe, _from, :wedge), do: {:noreply, :wedge}
  end

  setup do
    _ = Application.ensure_all_started(:horde)
    ensure_started(Routing)
    ensure_started(Budget)

    # A Governor refuses to regulate a cluster it cannot see itself in, which is
    # what stops a fresh one from buying a machine against an empty replica. On
    # a box running Hyper the advertiser has already published this; under
    # `--no-start` nothing has, so the test does.
    advertise_self!()

    name = :"fleet_sup_#{System.unique_integer([:positive])}"

    supervisor =
      start_supervised!(
        {Horde.DynamicSupervisor, name: name, strategy: :one_for_one, members: :auto}
      )

    %{supervisor: name, supervisor_pid: supervisor}
  end

  describe "listing" do
    test "a provider that cannot be listed changes nothing", ctx do
      state = active(ctx, list: {:error, :api_down}, capabilities: [:create, :destroy])

      after_tick = Governor.tick(state)

      assert after_tick.role == :active
      assert after_tick.last_change == nil
      assert children(ctx) == []
      refute_receive {:create, _tags}, 200
      refute_receive {:destroy, _id}, 200
    end

    test "a provider that cannot even be built is retried, not crashed on", ctx do
      state =
        active(ctx, init: {:error, :bad_credential}, list: [], capabilities: [:create, :destroy])

      once = Governor.tick(state)

      assert once.provider_state == nil
      assert once.last_change == nil
      assert children(ctx) == []

      # A rotated credential must not escalate into a node-wide outage: the
      # Governor is a `:one_for_one` child of `Hyper.Cluster`, so a raise here
      # would blow restart intensity and take the routing and budget registries
      # with it. The next tick simply asks again.
      _twice = Governor.tick(once)

      assert_receive :provider_init
      assert_receive :provider_init
      refute_receive {:create, _tags}, 200
    end
  end

  describe "configuration" do
    test "a fleet configuration that will not load leaves the governor inert, not dead", ctx do
      Application.put_env(:hyper, Hyper.Cfg.Fleet, min_nodes: -1)
      on_exit(fn -> Application.delete_env(:hyper, Hyper.Cfg.Fleet) end)

      state = %Governor{supervisor: ctx.supervisor, role: :active}

      assert %Governor{} = after_tick = Governor.tick(state)
      assert after_tick.cfg == nil
      assert after_tick.last_change == nil
      assert Governor.warned?(after_tick, :config)
      assert children(ctx) == []
    end
  end

  describe "adoption" do
    test "starts exactly one controller per listed machine, on every tick", ctx do
      infos = [info(unique("a")), info(unique("b"))]
      state = active(ctx, list: infos, capabilities: [])

      state = Governor.tick(state)
      pids = children(ctx)
      assert length(pids) == 2

      for %Info{id: id} <- infos, do: assert(await_registered({:machine, id}))
      _ = Governor.tick(state)

      assert children(ctx) == pids
    end

    test "never starts a second controller for a machine that already has one" do
      id = unique("adopted")
      start_supervised!({StubController, {summary(id, :ready), self()}})
      assert await_registered({:machine, id})

      # The supervisor name is deliberately unregistered: any attempt to start a
      # controller would exit here, so completing the tick is what proves the
      # registry check ran before the start and not the controller's own refusal
      # after it.
      state = active(@absent_supervisor, list: [info(id)], capabilities: [])

      assert %Governor{} = Governor.tick(state)
    end
  end

  @growth_rows [
    {"an idle fleet and a clean cooldown", :never, nil, :creates},
    {"a size change inside the cooldown", :now, nil, :suppressed},
    {"a machine already ordered and not yet joined", :never, :awaiting_join, :suppressed}
  ]

  describe "growth" do
    for {desc, clock, phase, expect} <- @growth_rows do
      test "wanted capacity, #{desc}: #{expect}", ctx do
        {clock, phase, expect} = {unquote(clock), unquote(phase), unquote(expect)}
        _ = occupy(phase, self())

        state = with_clock(active(ctx, list: [], capabilities: [:create]), clock)

        assert_growth(expect, Governor.tick(state), state)
      end
    end

    test "an observe-only provider reports the shortage once and never creates", ctx do
      state = active(ctx, list: [], capabilities: [])

      once = Governor.tick(state)
      assert Governor.warned?(once, :create)
      assert once.last_change == nil

      assert Governor.tick(once) == once
      assert children(ctx) == []
      refute_receive {:create, _tags}, 200
    end
  end

  @reclaim_rows [
    {:draining, :reclaimed},
    {:cordoned, :left_alone},
    {:ready, :left_alone}
  ]

  describe "reclaiming" do
    for {phase, expect} <- @reclaim_rows do
      test "a #{phase} machine is #{expect} when the fleet wants capacity" do
        {phase, expect} = {unquote(phase), unquote(expect)}
        id = occupy(phase, self())

        # Observe-only, and a supervisor that does not exist: reclaiming is the
        # only growth this tick could possibly perform.
        state = active(@absent_supervisor, list: [], capabilities: [])

        assert_reclaim(expect, Governor.tick(state), id)
      end
    end
  end

  # Draining is the only path in Fleet that ends in a machine being destroyed,
  # so every combination of "who owns the emptiest node" is driven. The fleet is
  # seeded with an *unmanaged* node emptier than the managed one: a policy that
  # did not know which nodes are drainable would name that one every tick, and a
  # Governor that then just held would leave the fleet unable to ever shrink.
  @shrink_rows [
    {"a ready controller owns it", :ready, :its_own, :drains},
    {"its controller has not joined yet", :awaiting_join, :its_own, :holds},
    {"the only controller owns another node", :ready, :elsewhere, :holds},
    {"no controller owns it", :none, :its_own, :holds}
  ]

  describe "scale-in" do
    for {desc, phase, ownership, expect} <- @shrink_rows do
      test "the emptiest drainable machine is drained — #{desc}: #{expect}", ctx do
        {phase, ownership, expect} = {unquote(phase), unquote(ownership), unquote(expect)}

        drainable = fleet_node("drainable", Information.gib(64))
        _idle_orphan = fleet_node("orphan", Information.gib(4096))
        id = own(phase, node_for(ownership, drainable))

        state = shrinkable(ctx)

        assert_shrink(expect, Governor.tick(state), id)
      end
    end

    test "a size change inside the cooldown suppresses a shrink, not only a grow", ctx do
      drainable = fleet_node("drainable", Information.gib(64))
      id = own(:ready, drainable)

      state = with_clock(shrinkable(ctx), :now)

      after_tick = Governor.tick(state)

      refute_receive {:called, :drain, ^id}, 200
      assert after_tick.last_change == state.last_change
    end
  end

  describe "unanswerable controllers" do
    test "a controller that crashes or wedges when asked is skipped, and the tick completes",
         ctx do
      start_supervised!(%{
        id: :crashy,
        start: {MuteController, :start_link, [{unique("crashy"), :crash}]}
      })

      start_supervised!(%{
        id: :wedged,
        start: {MuteController, :start_link, [{unique("wedged"), :wedge}]}
      })

      # A machine that *can* answer, in a phase that would suppress growth: if
      # its summary survived the two that cannot, no machine is ordered.
      _quiet = occupy(:awaiting_join, self())

      state = active(ctx, list: [], capabilities: [:create])

      assert %Governor{} = Governor.tick(state)
      refute_receive {:create, _tags}, 200
    end
  end

  describe "election" do
    test "registering the singleton key is a claim, not a win", ctx do
      state = %{active(ctx, list: [], capabilities: []) | role: :standby}
      expected = if free_singleton?(), do: :active, else: :standby

      # Both nodes of a simultaneous boot get `{:ok, _}` from `register/3`: it
      # answers from the local replica, which neither peer has reached yet. A
      # Governor that promoted itself on that answer could order a machine the
      # winner is also ordering, so promotion waits to see the key resolved.
      first = Governor.tick(state)
      assert first.role == :standby
      assert children(ctx) == []

      assert await_registered(@singleton_key)
      assert Governor.tick(first).role == expected
    end

    test "a standby governor takes no action and does not even ask the provider", ctx do
      hold_singleton()

      state = %{
        active(ctx, list: [info(unique("ignored"))], capabilities: [:create])
        | role: :standby
      }

      after_tick = Governor.tick(state)

      assert after_tick.role == :standby
      assert after_tick.provider_state == nil
      assert children(ctx) == []
    end
  end

  # The row's expectation arrives as an argument rather than being matched
  # inline in the generated test body: with the literal in scope the compiler
  # narrows it to a single atom and reports the other clause as unreachable.
  defp assert_growth(:creates, after_tick, _before) do
    assert_receive {:create, tags}, 2_000
    assert Map.has_key?(tags, Machine.claim_tag())
    assert after_tick.last_change != nil
  end

  defp assert_growth(:suppressed, after_tick, before) do
    refute_receive {:create, _tags}, 200
    assert after_tick.last_change == before.last_change
  end

  defp assert_reclaim(:reclaimed, after_tick, id) do
    assert_receive {:called, :uncordon, ^id}, 1_000
    assert after_tick.last_change != nil
  end

  defp assert_reclaim(:left_alone, after_tick, id) do
    refute_receive {:called, _event, ^id}, 200
    assert after_tick.last_change == nil
  end

  defp assert_shrink(:drains, after_tick, id) do
    assert_receive {:called, :drain, ^id}, 1_000
    assert after_tick.last_change != nil
  end

  defp assert_shrink(:holds, after_tick, _id) do
    refute_receive {:called, _event, _id}, 200
    assert after_tick.last_change == nil
  end

  defp active(ctx, provider_opts) do
    %Governor{
      cfg: cfg(Keyword.put(provider_opts, :owner, self())),
      supervisor: ctx.supervisor,
      role: :active
    }
  end

  # An active Governor over an empty provider listing whose only possible
  # decision is a scale-in: nothing is wanted (`min_nodes: 0`, no headroom
  # target) and nothing can be bought.
  defp shrinkable(ctx) do
    state = active(ctx, list: [], capabilities: [])
    %{state | cfg: %{state.cfg | min_nodes: 0, target_headroom: 0}}
  end

  # `min_nodes` is above anything the ambient cluster can supply, so
  # `Hyper.Cluster.Fleet.Policy` answers `{:grow, 1}` whether or not this VM is
  # running a real node's budget advertiser. The deadlines are long enough that
  # no controller started here reaches one during the test.
  defp cfg(provider_opts) do
    %Hyper.Cfg.Fleet{
      provider: StubProvider,
      provider_opts: provider_opts,
      min_nodes: 50,
      max_nodes: nil,
      target_headroom: 1,
      reference_type: :base,
      cooldown: Time.s(120),
      provision_deadline: Time.s(600),
      nodedown_grace: Time.s(300),
      drain_deadline: Time.s(1800)
    }
  end

  defp with_clock(state, :never), do: state
  defp with_clock(state, :now), do: %{state | last_change: System.monotonic_time(:millisecond)}

  defp occupy(nil, _owner), do: nil

  defp occupy(phase, owner) do
    id = unique(phase)
    start_supervised!({StubController, {summary(id, phase), owner}})
    assert await_registered({:machine, id})
    id
  end

  # A stub controller in `phase` claiming to own `node`, which is what makes the
  # difference between a node Fleet may drain and one it may not.
  defp own(:none, _node), do: nil

  defp own(phase, node) do
    id = unique(phase)
    start_supervised!({StubController, {%{summary(id, phase) | node: node}, self()}})
    assert await_registered({:machine, id})
    id
  end

  defp node_for(:its_own, node), do: node
  defp node_for(:elsewhere, _node), do: :somewhere@else

  # A node in the cluster's budget replica, free enough to be a shrink candidate.
  defp fleet_node(label, mem_free) do
    node = :"#{unique(label)}@nowhere"

    {:ok, _pid} =
      Horde.Registry.register(Budget.name(), {:node, node}, node_state(node, mem_free))

    assert await_advertised(node)
    node
  end

  defp advertise_self! do
    case Horde.Registry.register(
           Budget.name(),
           Budget.key(),
           node_state(node(), Information.gib(1))
         ) do
      {:ok, _pid} -> assert await_advertised(node())
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  # Only the free-memory dimension varies: everything else is far beyond what a
  # reference instance asks for, so a node's placeable count is exactly the
  # memory it has left.
  defp node_state(node, mem_free) do
    %NodeState{
      node: node,
      mem_free: mem_free,
      disk_free: Information.tib(100),
      cpu_load: 0.0,
      cpu_capacity: 4096,
      cpu_max_load: 1.0,
      disk_bw_load: Bandwidth.zero(),
      disk_bw_ceiling: Bandwidth.tibps(1),
      net_bw_load: Bandwidth.zero(),
      net_bw_ceiling: Bandwidth.tibps(1),
      layers: [],
      drain: false
    }
  end

  defp info(id) do
    %Info{id: id, node: :"#{id}@nowhere", status: :active, tags: %{"fleet" => "test"}}
  end

  defp summary(id, phase) do
    %{id: id, provider_id: id, node: :"#{id}@nowhere", phase: phase, tags: %{}}
  end

  defp unique(prefix), do: "gov-#{prefix}-#{System.unique_integer([:positive])}"

  defp children(ctx) do
    ctx.supervisor
    |> Horde.DynamicSupervisor.which_children()
    |> Enum.map(fn {_id, pid, _type, _mods} -> pid end)
    |> Enum.sort()
  end

  # The singleton is a fixed, cluster-global key. Something already holding it
  # (a Governor the application started under `mix check`) is exactly the
  # condition under test; otherwise a holder is started for the test's duration.
  defp hold_singleton do
    case Horde.Registry.lookup(Routing.name(), @singleton_key) do
      [] -> claim_singleton()
      [_taken] -> :ok
    end
  end

  defp free_singleton?, do: Horde.Registry.lookup(Routing.name(), @singleton_key) == []

  defp claim_singleton do
    {:ok, holder} =
      Agent.start(fn -> Horde.Registry.register(Routing.name(), @singleton_key, nil) end)

    on_exit(fn -> if Process.alive?(holder), do: Agent.stop(holder) end)
    assert await_registered(@singleton_key)
  end

  defp ensure_started(mod) do
    if Process.whereis(mod) do
      :ok
    else
      case start_supervised(mod) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  # Horde materialises a registration into the local replica asynchronously, so a
  # test that registers and then expects a lookup to see it must poll.
  defp await_registered(key, tries \\ 200)
  defp await_registered(_key, 0), do: false

  defp await_registered(key, tries) do
    if Horde.Registry.lookup(Routing.name(), key) != [] do
      true
    else
      Process.sleep(5)
      await_registered(key, tries - 1)
    end
  end

  defp await_advertised(node, tries \\ 200)
  defp await_advertised(_node, 0), do: false

  defp await_advertised(node, tries) do
    if Enum.any?(Budget.all_states(), &(&1.node == node)) do
      true
    else
      Process.sleep(5)
      await_advertised(node, tries - 1)
    end
  end
end
