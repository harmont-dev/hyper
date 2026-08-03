defmodule Hyper.Cluster.Fleet.MachineTest do
  # async: false - drives the process-global Horde registries (`Hyper.Cluster.Routing`
  # and `Hyper.Cluster.Budget`), which the controller reads through.
  use ExUnit.Case, async: false

  @moduledoc """
  The lifecycle decisions of the machine controller — the classifications that
  decide whether a machine is waited for, retried, reclaimed or paid to stop
  existing. Each one is driven at the phase handler with a hand-built data
  struct, against a programmable stub provider, so the assertion is on the
  returned `:gen_statem` transition rather than on a mock:

    * **creation is claimed** — a controller whose claim already names a machine
      adopts it and never calls `create/2` again. This is the guard against the
      one operation no provider can make idempotent, and the failure it prevents
      (a second machine per crash) costs real money.
    * **failure is a state, not a crash** — a failed create backs off with a
      growing delay and returns to `:requested` (which reconciles first). Under
      Horde a crash loop is charged to every controller on the node.
    * **a machine is only given up on if it can be replaced** — the provision
      deadline and the nodedown grace terminate under a provider that can
      create, and lapse into an indefinite wait under one that cannot.
    * **a drain never destroys running VMs** — draining polls the routing
      registry for zero and, at its deadline, holds the machine cordoned rather
      than destroying the work on it.
    * **a cordon is reversible** — a draining machine is reclaimed by
      `uncordon`, because one already paid for and already joined beats
      provisioning a replacement.
    * **destroy is asked for exactly once it is both possible and warranted** —
      never for a machine that was never created, never of a provider that does
      not declare `:destroy`, never while VMs are still on the machine, and
      bounded when it keeps failing.
    * **losing contact is not evidence** — an expired nodedown grace destroys
      nothing until the provider agrees the machine is not there, because a
      partition and a dead machine look identical from this side.

  The cordon is exercised for real against `node()` itself, which is a reachable
  peer like any other: the flag those tests set and read is the same
  `Hyper.Node.Cordon` a remote controller would drive by `:erpc`. Cordoning an
  actually-remote node is integration territory and is not faked here; a
  controller pointed at one of the unreachable fixture nodes takes the "an
  unreachable node is already unschedulable" path instead.
  """

  @moduletag :capture_log

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Fleet.Machine
  alias Hyper.Cluster.Fleet.Machine.AwaitingJoin
  alias Hyper.Cluster.Fleet.Machine.Cordoned
  alias Hyper.Cluster.Fleet.Machine.Draining
  alias Hyper.Cluster.Fleet.Machine.Failed
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Fleet.Machine.Provisioning
  alias Hyper.Cluster.Fleet.Machine.Ready
  alias Hyper.Cluster.Fleet.Machine.Requested
  alias Hyper.Cluster.Fleet.Machine.Terminating
  alias Hyper.Cluster.Fleet.Machine.Unreachable
  alias Hyper.Cluster.Routing
  alias Hyper.Node.Cordon

  defmodule StubProvider do
    @moduledoc """
    A provider whose every answer is read from an `Agent` the test owns, and which
    reports each mutation it is asked for back to that test. Programmable failure
    is the point: `create/2` failing and `destroy/2` failing are normal provider
    behaviour, not exceptional.
    """

    @behaviour Hyper.Cluster.Fleet.Provider

    @impl Hyper.Cluster.Fleet.Provider
    def init(opts), do: {:ok, Keyword.fetch!(opts, :agent)}

    @impl Hyper.Cluster.Fleet.Provider
    def capabilities(agent), do: Agent.get(agent, & &1.capabilities)

    @impl Hyper.Cluster.Fleet.Provider
    def list(agent), do: Agent.get(agent, & &1.list)

    @impl Hyper.Cluster.Fleet.Provider
    def create(agent, tags) do
      %{owner: owner, create: result} = Agent.get(agent, & &1)
      send(owner, {:provider_create, tags})
      result
    end

    @impl Hyper.Cluster.Fleet.Provider
    def destroy(agent, id) do
      %{owner: owner, destroy: result} = Agent.get(agent, & &1)
      send(owner, {:provider_destroy, id})
      result
    end
  end

  defmodule VmStub do
    @moduledoc "Stands in for a VM supervisor so `Hyper.Cluster.Routing.all/0` counts it."

    use GenServer

    def start_link(vm_id), do: GenServer.start_link(__MODULE__, vm_id)

    @impl GenServer
    def init(vm_id) do
      :ok = Routing.register_self({vm_id, :supervisor})
      {:ok, vm_id}
    end
  end

  setup do
    ensure_registry(Routing)
    ensure_registry(Budget)

    # Several phases now re-assert the cordon on their poll, and the machine
    # under test is sometimes this very node: leaving that flag set would make
    # every later `NodeState.build/0` in the run advertise a drain.
    on_exit(&uncordon_self/0)
    :ok
  end

  describe "child specs" do
    test "the claim is minted into the args Horde replays, and replaying them is a fixed point" do
      spec = Machine.child_spec(cfg: cfg(provider([])), entry: {:create, %{}})

      assert %{id: {Machine, id}, start: {Machine, :start_link, [args]}, restart: :transient} =
               spec

      # The claim has to be *in the recorded arguments*, not minted in `init/1`:
      # Horde replays this MFA verbatim on every crash and hand-off, and a fresh
      # claim there would reconcile against nothing and buy a second machine.
      assert {:create, tags} = Keyword.fetch!(args, :entry)
      assert Map.fetch!(tags, Machine.claim_tag()) == id
      assert Machine.child_spec(args).id == spec.id
      assert Machine.child_spec(args).start == spec.start
    end

    test "an adopted machine is identified by the machine, not by a claim of ours" do
      info = %Info{id: unique("prov"), status: :active, tags: %{}}
      spec = Machine.child_spec(cfg: cfg(provider([])), entry: {:adopt, info})

      assert spec.id == {Machine, Machine.key(info)}
      assert spec.restart == :transient
    end
  end

  describe "creating a machine" do
    test "a claim that already names a machine is adopted, never created twice" do
      claim = unique("claim")
      node = unique_node()

      existing = %Info{
        id: "prov-1",
        status: :active,
        node: node,
        tags: %{Machine.claim_tag() => claim}
      }

      # A machine belonging to someone else is in the same listing: identity is
      # what selects ours, not "the provider returned something".
      agent = provider(list: {:ok, [%Info{id: "not-ours", status: :active}, existing]})
      data = claiming(agent, claim)

      assert {:next_state, :awaiting_join, adopted, [{:state_timeout, 0, :poll}]} =
               Requested.handle(:state_timeout, :reconcile, data)

      assert adopted.provider_id == "prov-1"
      assert adopted.node == node
      refute_receive {:provider_create, _}, 50
    end

    test "a claim that names nothing yet is created once, carrying that claim" do
      claim = unique("claim")
      agent = provider(list: {:ok, [%Info{id: "not-ours", status: :active}]})
      data = claiming(agent, claim)

      assert {:next_state, :provisioning, provisioning, [{:state_timeout, budget, :deadline}]} =
               Requested.handle(:state_timeout, :reconcile, data)

      # The create is handed to a task so the deadline can still fire under a
      # provider that blocks for minutes.
      assert {pid, ref} = provisioning.creator
      assert is_pid(pid) and is_reference(ref)
      assert budget > 0

      assert_receive {:provider_create, tags}
      assert tags[Machine.claim_tag()] == claim
    end

    test "a provider that cannot create is a refusal to stop on, not a loop" do
      agent = provider(capabilities: [], list: {:ok, []})

      assert {:stop, {:shutdown, :create_unsupported}, _data} =
               Requested.handle(:state_timeout, :reconcile, claiming(agent, unique("claim")))

      refute_receive {:provider_create, _}, 50
    end

    test "a failed create backs off, grows the backoff, and reconciles before retrying" do
      agent = provider([])
      first_try = %{claiming(agent, unique("claim")) | creator: {self(), make_ref()}}

      assert {:next_state, :failed, once, [{:state_timeout, first_delay, :retry}]} =
               Provisioning.handle(:info, {:created, self(), {:error, :quota}}, first_try)

      assert once.failures == 1
      assert once.creator == nil
      assert first_delay > 0

      second_try = %{once | creator: {self(), make_ref()}}

      assert {:next_state, :failed, twice, [{:state_timeout, second_delay, :retry}]} =
               Provisioning.handle(:info, {:created, self(), {:error, :quota}}, second_try)

      assert twice.failures == 2
      assert second_delay > first_delay

      # The retry re-enters `:requested`, whose first act is to reconcile - which
      # is what makes a retry safe after a create that may secretly have worked.
      assert {:next_state, :requested, _data, [{:state_timeout, 0, :reconcile}]} =
               Failed.handle(:state_timeout, :retry, twice)
    end

    test "a create task that dies without answering is a retry, not a controller crash" do
      agent = provider([])
      creator = {self(), make_ref()}
      data = %{claiming(agent, unique("claim")) | creator: creator}
      {pid, ref} = creator

      assert {:next_state, :failed, failed, [{:state_timeout, _delay, :retry}]} =
               Provisioning.handle(:info, {:DOWN, ref, :process, pid, :killed}, data)

      assert failed.failures == 1
    end
  end

  describe "waiting for a machine to join" do
    test "the wait ends at the provision deadline only when the machine can be replaced" do
      node = unique_node()

      before_deadline = adopted(provider([]), node: node, deadline: in_a_minute())

      assert {:keep_state, _data, [{:state_timeout, poll, :poll}]} =
               AwaitingJoin.handle(:state_timeout, :poll, before_deadline)

      assert poll > 0

      assert {:next_state, :terminating, _data, [{:state_timeout, 0, :destroy}]} =
               AwaitingJoin.handle(:state_timeout, :poll, %{before_deadline | deadline: lapsed()})

      # An observe-only fleet's machines are the operator's declaration: a node
      # that is down is expected back, and there is nothing to replace it with.
      observe_only =
        adopted(provider(capabilities: []), node: unique_node(), deadline: lapsed())

      assert {:keep_state, held, [{:state_timeout, _poll, :poll}]} =
               AwaitingJoin.handle(:state_timeout, :poll, observe_only)

      assert held.deadline == nil
    end

    test "a joined node ends the wait" do
      node = unique_node()
      join!(node)
      data = adopted(provider([]), node: node, deadline: in_a_minute())

      assert {:next_state, :ready, ready} = AwaitingJoin.handle(:state_timeout, :poll, data)
      assert ready.deadline == nil
    end
  end

  describe "losing a machine" do
    test "a nodedown grace recovers into the phase it interrupted" do
      node = unique_node()
      data = adopted(provider([]), node: node)

      assert {:next_state, :unreachable, gone, [{:state_timeout, 0, :poll}]} =
               Machine.handle_event(:info, {:nodedown, node}, :draining, data)

      assert gone.resume == :draining
      assert gone.deadline != nil

      assert {:keep_state, _data, [{:state_timeout, _poll, :poll}]} =
               Unreachable.handle(:state_timeout, :poll, gone)

      join!(node)

      assert {:next_state, :draining, back, [{:state_timeout, 0, :poll}]} =
               Unreachable.handle(:state_timeout, :poll, gone)

      # The drain deadline is re-established rather than inherited from the
      # grace timer that replaced it.
      assert back.resume == nil
      assert back.deadline != nil
    end

    test "a nodedown for another node, or in a phase with no monitor, changes nothing" do
      node = unique_node()
      data = adopted(provider([]), node: node)

      assert Machine.handle_event(:info, {:nodedown, unique_node()}, :ready, data) ==
               :keep_state_and_data

      assert Machine.handle_event(:info, {:nodedown, node}, :awaiting_join, data) ==
               :keep_state_and_data
    end

    # The grace lapsing says only that *we* cannot reach the machine, which is
    # exactly what the minority side of a partition sees while the majority side
    # keeps serving the VMs on it. So the provider has to agree before anything
    # is destroyed. Rows differ only in what the provider answers.
    @corroboration [
      {"no longer lists the machine", {:ok, []}, :written_off},
      {"reports it broken", {:ok, [%Info{id: "prov-1", status: :error}]}, :written_off},
      {"reports it gone", {:ok, [%Info{id: "prov-1", status: :gone}]}, :written_off},
      {"still reports it active", {:ok, [%Info{id: "prov-1", status: :active}]}, :kept},
      {"still reports it pending", {:ok, [%Info{id: "prov-1", status: :pending}]}, :kept},
      {"cannot be asked at all", {:error, :api_down}, :kept}
    ]

    test "an expired grace writes the machine off only if the provider agrees it is not there" do
      for {desc, listing, expected} <- @corroboration do
        agent = provider(list: listing)
        data = %{adopted(agent, node: unique_node(), resume: :ready) | id: "prov-1"}

        assert_expiry(expected, Unreachable.handle(:state_timeout, :poll, lapse(data)), desc)
      end
    end

    test "a machine that cannot be replaced is waited for however long the grace was" do
      data = adopted(provider(capabilities: []), node: unique_node(), resume: :ready)

      assert {:keep_state, held, [{:state_timeout, _poll, :poll}]} =
               Unreachable.handle(:state_timeout, :poll, lapse(data))

      # Re-armed rather than cleared: the wait is indefinite, but each period
      # ends in one log line instead of one per five-second poll.
      assert held.deadline != nil
    end

    # `:error` means "replace this machine", and a machine being replaced may
    # still be running someone's VMs. Only one that never joined and holds
    # nothing goes straight out.
    @observations [
      {:gone, :absent, :terminating},
      {:error, :absent, :terminating},
      {:error, :joined, :draining}
    ]

    test "a machine the provider condemns is drained if it is in the cluster, retired if not" do
      for {status, membership, expected} <- @observations do
        node = unique_node()
        if membership == :joined, do: join!(node)
        data = adopted(provider([]), node: node)

        assert {^expected, observed, _actions} =
                 Machine.observed(%Info{id: "prov-1", status: status}, data),
               "#{status} on a #{membership} node"

        assert observed.provider_id == "prov-1"
      end
    end
  end

  describe "cordoning and draining" do
    test "cordon holds placement back and uncordon gives it straight back" do
      data = adopted(provider([]), node: unique_node())
      from = {self(), make_ref()}

      assert {:next_state, :cordoned, cordoned, [{:reply, ^from, :ok} | _timers]} =
               Ready.handle({:call, from}, :cordon, data)

      # A cordon is not a countdown: nothing is scheduled to happen *to the
      # machine*. The only timer is the one that re-asserts the flag.
      assert cordoned.deadline == nil

      assert {:next_state, :ready, _data, [{:reply, ^from, :ok}]} =
               Cordoned.handle({:call, from}, :uncordon, cordoned)
    end

    test "drain arms a deadline that cordon does not" do
      data = adopted(provider([]), node: unique_node())
      from = {self(), make_ref()}

      assert {:next_state, :draining, draining,
              [{:reply, ^from, :ok}, {:state_timeout, 0, :poll}]} =
               Ready.handle({:call, from}, :drain, data)

      assert draining.deadline != nil
    end

    test "a machine with a VM on it is waited for, and destroyed only once it is empty" do
      vm_id = unique("vm")
      _vm = start_supervised!(%{id: :vm_stub, start: {VmStub, :start_link, [vm_id]}})
      await(fn -> vm_id in vms_here() end)

      data = adopted(provider([]), node: node(), provider_id: "prov-1", deadline: in_a_minute())

      assert {:keep_state_and_data, [{:state_timeout, poll, :poll}]} =
               Draining.handle(:state_timeout, :poll, data)

      assert poll > 0
      refute_receive {:provider_destroy, _}, 50

      # `stop_supervised!` rather than stopping the pid: a supervised child would
      # simply be restarted and the machine would never look empty.
      :ok = stop_supervised!(:vm_stub)
      await(fn -> vms_here() == [] end)

      assert {:next_state, :terminating, empty, [{:state_timeout, 0, :destroy}]} =
               Draining.handle(:state_timeout, :poll, data)

      assert {:stop, {:shutdown, :destroyed}, _data} =
               Terminating.handle(:state_timeout, :destroy, empty)

      assert_receive {:provider_destroy, "prov-1"}
    end

    test "the drain deadline holds the machine cordoned rather than destroying its VMs" do
      vm_id = unique("vm")
      _vm = start_supervised!(%{id: :vm_stub, start: {VmStub, :start_link, [vm_id]}})
      await(fn -> vm_id in vms_here() end)

      data = adopted(provider([]), node: node(), provider_id: "prov-1", deadline: lapsed())

      assert {:next_state, :cordoned, held, _timers} =
               Draining.handle(:state_timeout, :poll, data)

      assert held.deadline == nil
      refute_receive {:provider_destroy, _}, 50
    end

    test "a draining machine is reclaimed by uncordon instead of replaced" do
      data = adopted(provider([]), node: unique_node(), deadline: in_a_minute())
      from = {self(), make_ref()}

      assert {:next_state, :ready, reclaimed, [{:reply, ^from, :ok}]} =
               Draining.handle({:call, from}, :uncordon, data)

      assert reclaimed.deadline == nil
      refute_receive {:provider_destroy, _}, 50
    end
  end

  describe "terminating" do
    @terminations [
      {"a destroyable machine is destroyed", [:create, :destroy], "prov-1", ["prov-1"]},
      {"a provider without :destroy is never asked", [:create], "prov-1", []},
      {"a machine that was never created has nothing to destroy", [:destroy], nil, []}
    ]

    test "the controller always stops, and asks for a destroy only when it may" do
      for {label, capabilities, provider_id, expected} <- @terminations do
        agent = provider(capabilities: capabilities)
        data = adopted(agent, provider_id: provider_id)

        assert {:stop, {:shutdown, _reason}, _data} =
                 Terminating.handle(:state_timeout, :destroy, data)

        assert destroys_seen() == expected, label
      end
    end

    # The guard lives on the destroy edge rather than on the four paths that
    # reach it, so it holds for *every* reason a machine ends up here: a vendor
    # calling the machine broken, a lapsed deadline, a write-off. Whatever the
    # reason, the VMs on it are not part of the argument.
    test "a machine with VMs on it is drained instead of destroyed, whatever sent it here" do
      vm_id = unique("vm")
      _vm = start_supervised!(%{id: :vm_stub, start: {VmStub, :start_link, [vm_id]}})
      await(fn -> vm_id in vms_here() end)

      data = adopted(provider([]), node: node(), provider_id: "prov-1")

      assert {:next_state, :draining, draining, [{:state_timeout, 0, :poll}]} =
               Terminating.handle(:state_timeout, :destroy, data)

      assert draining.deadline != nil
      refute_receive {:provider_destroy, _}, 50
    end

    test "a destroy that keeps failing is retried, then handed back to the governor" do
      agent = provider(destroy: {:error, :api_down})
      data = adopted(agent, provider_id: "prov-1")

      assert {:keep_state, once, [{:state_timeout, delay, :destroy}]} =
               Terminating.handle(:state_timeout, :destroy, data)

      assert once.failures == 1
      assert delay > 0

      exhausted = %{data | failures: Machine.destroy_attempts() - 1}

      assert {:stop, {:shutdown, {:destroy_failed, :api_down}}, _data} =
               Terminating.handle(:state_timeout, :destroy, exhausted)
    end
  end

  # `node()` is a reachable peer, so these drive the real `Hyper.Node.Cordon`
  # rather than the transport-failure path every other test here takes.
  describe "the cordon on the machine's own node" do
    setup do
      if is_nil(Process.whereis(Cordon)), do: start_supervised!(Cordon)
      :ok = Cordon.set(false)
      :ok
    end

    test "cordon and drain assert the flag, and their polls re-assert it" do
      data = adopted(provider([]), node: node())
      from = {self(), make_ref()}

      assert {:next_state, :cordoned, _cordoned, _actions} =
               Ready.handle({:call, from}, :cordon, data)

      assert Cordon.drained?()

      # Nothing on the far side persists that flag: a reboot, or a restart of
      # its `Hyper.Node.Cordon`, clears it while the node stays in distribution,
      # so no nodedown fires and only the poll notices. A drain whose cordon has
      # quietly lapsed is a drain that never finishes.
      for phase <- [Cordoned, Draining] do
        :ok = Cordon.set(false)
        _ = phase.handle(:state_timeout, :poll, data)
        assert Cordon.drained?(), "#{inspect(phase)} did not re-assert the cordon"
      end
    end

    test "uncordon clears the flag from :ready, where this controller never set it" do
      :ok = Cordon.set(true)
      data = adopted(provider([]), node: node())
      from = {self(), make_ref()}

      # A controller lands in `:ready` after every crash and hand-off, so "we
      # never cordoned it" says nothing about what the node is advertising —
      # and this is the operator's only lever over a node stuck that way.
      assert {:keep_state_and_data, [{:reply, ^from, :ok}]} =
               Ready.handle({:call, from}, :uncordon, data)

      refute Cordon.drained?()
    end

    @adoptions [{true, :cordoned}, {false, :ready}]

    test "a joining node's own cordon decides the phase, rather than being assumed" do
      join_self!()
      data = adopted(provider([]), node: node(), deadline: in_a_minute())

      for {cordoned?, expected} <- @adoptions do
        :ok = Cordon.set(cordoned?)

        assert phase_of(AwaitingJoin.handle(:state_timeout, :poll, data)) == expected,
               "a node advertising drain=#{cordoned?} was adopted as #{expected}"
      end
    end
  end

  describe "the controller as a process" do
    test "adopting an active machine whose node has joined starts ready, and only one may exist" do
      node = unique_node()
      join!(node)

      info = %Info{id: unique("prov"), status: :active, node: node, tags: %{}}
      opts = [cfg: cfg(provider(list: {:ok, [info]})), entry: {:adopt, info}]

      pid = start_supervised!(%{id: :machine, start: {Machine, :start_link, [opts]}})
      await(fn -> Horde.Registry.lookup(Routing.name(), {:machine, info.id}) != [] end)

      # `:awaiting_join` is entered with a zero timeout and left again on the
      # same tick, because the node is already in the budget registry.
      assert {:ready, data} = :sys.get_state(pid)
      assert data.node == node

      assert %{phase: :ready, provider_id: id} = Machine.describe(info.id)
      assert id == info.id

      # The registration is the whole defence against two controllers for one
      # machine: the loser must decline to run, not run anyway.
      assert Machine.start_link(opts) == :ignore
    end
  end

  defp provider(opts) do
    defaults = %{
      owner: self(),
      capabilities: [:create, :destroy],
      list: {:ok, []},
      create: {:error, :not_now},
      destroy: :ok
    }

    {:ok, agent} = Agent.start_link(fn -> Map.merge(defaults, Map.new(opts)) end)
    agent
  end

  defp cfg(agent) do
    %Config{
      provider: StubProvider,
      provider_opts: [agent: agent],
      min_nodes: 0,
      max_nodes: nil,
      target_headroom: 1,
      reference_type: :base,
      cooldown: Unit.Time.s(120),
      provision_deadline: Unit.Time.s(600),
      nodedown_grace: Unit.Time.s(300),
      drain_deadline: Unit.Time.s(1800)
    }
  end

  # Controller data as it is while it owes the provider a machine.
  defp claiming(agent, claim) do
    tags = %{Machine.claim_tag() => claim}

    %Machine{
      cfg: cfg(agent),
      id: claim,
      tags: tags,
      provider_state: agent,
      deadline: in_a_minute()
    }
  end

  # Controller data as it is once a machine is known to exist.
  defp adopted(agent, fields) do
    struct!(
      %Machine{cfg: cfg(agent), id: "machine-under-test", tags: %{}, provider_state: agent},
      fields
    )
  end

  # The expectation arrives as an argument rather than being matched inline:
  # with the row's literal in scope the compiler narrows it to one atom and
  # reports the other clause as unreachable.
  defp assert_expiry(:written_off, result, desc) do
    assert {:next_state, :terminating, _data, [{:state_timeout, 0, :destroy}]} = result,
           "a provider that #{desc} should have let the write-off through"
  end

  defp assert_expiry(:kept, result, desc) do
    assert {:keep_state, held, [{:state_timeout, _poll, :poll}]} = result,
           "a provider that #{desc} is no reason to destroy the machine"

    assert held.deadline != nil, "the grace should be re-armed so this is re-checked, not spammed"
  end

  defp phase_of({:next_state, phase, _data}), do: phase
  defp phase_of({:next_state, phase, _data, _actions}), do: phase

  defp in_a_minute, do: System.monotonic_time(:millisecond) + 60_000
  defp lapsed, do: System.monotonic_time(:millisecond) - 1
  defp lapse(data), do: %{data | deadline: lapsed()}

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_node, do: String.to_atom(unique("machine") <> "@fleet.test")

  # Publish a budget record for `node`, which is what "the machine joined the
  # cluster" means to the controller. Only the node name is read from it, so the
  # fixture stays independent of the budget snapshot's evolving shape.
  defp join!(node) do
    {:ok, _pid} = Horde.Registry.register(Budget.name(), {:node, node}, %{node: node})
    await(fn -> Enum.any?(Budget.all_states(), &(&1.node == node)) end)
  end

  # This node, which on a box running Hyper has already published itself.
  defp join_self! do
    case Horde.Registry.register(Budget.name(), Budget.key(), %{node: node()}) do
      {:ok, _pid} -> await(fn -> Enum.any?(Budget.all_states(), &(&1.node == node())) end)
      {:error, {:already_registered, _pid}} -> :ok
    end
  end

  defp uncordon_self do
    if Process.whereis(Cordon), do: Cordon.set(false)
  end

  # The VMs the routing registry says are running on this test's own node - the
  # only ones a locally-registered `VmStub` can appear as.
  defp vms_here do
    Routing.all()
    |> Enum.filter(fn {_vm_id, on} -> on == node() end)
    |> Enum.map(fn {vm_id, _on} -> vm_id end)
  end

  defp destroys_seen do
    receive do
      {:provider_destroy, id} -> [id | destroys_seen()]
    after
      20 -> []
    end
  end

  # Horde materialises a registration into the local replica asynchronously.
  defp await(condition, tries \\ 200)
  defp await(_condition, 0), do: flunk("condition never became true")

  defp await(condition, tries) do
    if condition.() do
      :ok
    else
      Process.sleep(5)
      await(condition, tries - 1)
    end
  end

  # Under `mix test --no-start` the app's registries are absent; on a dev box
  # with the app running they already exist and are reused.
  defp ensure_registry(module) do
    if Process.whereis(module) do
      :ok
    else
      _ = Application.ensure_all_started(:horde)

      case start_supervised(module) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end
end
