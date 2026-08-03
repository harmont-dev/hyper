defmodule Hyper.Cluster.Fleet.Policy do
  @moduledoc """
  The scale decision for the machine fleet: given what the cluster looks like
  right now, should there be one more machine, one fewer, or no change?

  `decide/4` is a total, deterministic function of its arguments - no processes,
  no I/O, no clock, no registry. `Hyper.Cluster.Fleet.Governor` supplies the
  observations and owns everything stateful (cooldown, provider capabilities,
  who is actually told to cordon). Keeping the arithmetic here means the part
  that costs real money can be proved rather than watched.

  ## What gets measured

  Headroom, counted in whole **reference instances**: how many more
  `Hyper.Cfg.Fleet` `reference_type` VMs the cluster could still place. A count
  of VMs rather than a percentage is deliberate - a VM is the unit placement
  actually fails in, and `Hyper.Cluster.Scheduler` answers
  `{:error, :no_capacity}` exactly when this count hits zero.

  Per node the count comes from *filling the node up*: ask
  `Hyper.Node.Budget.NodeState.fits?/2`, debit the placed spec from the
  snapshot, ask again. `NodeState.fits?/2` stays the single authority on what
  fits; this module only models the debit, so a change to the fit rules cannot
  leave the policy behind. Memory and disk are debited exactly as
  `Hyper.Node.Budget.Hard` debits them for a real reservation, so the hard half
  of the count is exact. The soft metrics (cpu, disk bandwidth, net bandwidth)
  are charged the spec's *nominal* demand, which is the same charge the fit
  check already applies to the candidate VM. The result is therefore "how many
  VMs the scheduler would admit if every one of them ran at its nominal
  ceiling" - a lower bound on what the hardware absorbs. Erring low grows
  the fleet slightly early rather than refusing a placement, which is the side
  of that trade an operator pays for in money instead of in outages.

  Machines in flight (ordered, not yet joined) count as **pending headroom**,
  valued at the emptiest joined node's count. That is the closest available
  estimate of what an empty machine of this shape provides and, since no joined
  node can be emptier than a fresh one, a lower bound on it. Without pending
  headroom a single shortage would be answered once per tick until the first
  machine finished booting. When nothing has joined there is no estimate at
  all, and one outstanding order is credited with the whole target instead:
  grow by one, watch it join, re-evaluate. Feedback, not feedforward - the same
  shape as `Controls.Ewma`.

  A node advertising `drain: true` is cordoned: it contributes no headroom and is
  never a shrink candidate. Note the consequence an operator should expect —
  cordoning a machine by hand *does* lower the fleet's measured capacity, so if
  that drops headroom below `target_headroom` the regulator will buy capacity to
  replace it. A cordon is a statement that the machine is not available, and the
  policy takes it at its word.

  ## What the caller can act on

  Not every node in `Hyper.Cluster.Budget` is a node Fleet may drain.
  Hand-installed metal, a node from another deployment sharing the cookie, or a
  machine whose controller is still being adopted all contribute headroom while
  being nobody's to cordon — and naming one as the shrink target would be a
  decision that silently never happens, every tick, forever. So the Governor
  passes the set of nodes it actually holds a `:ready` controller for, and only
  those are candidates.

  The same view carries the nodes that are *already being drained*, which is what
  quiescence keys on. Keying it on the advertised `drain` flag instead would
  conflate "leaving the fleet" with "parked for a kernel upgrade", and one
  machine an operator cordoned on a Friday would block every scale-in in the
  cluster until they came back. Without that view (`:unmanaged`, the default)
  both questions fall back to the flag, which is the conservative reading.

  ## The size band

  `min_nodes`/`max_nodes` band the **committed** count - joined-and-not-draining
  machines plus machines in flight - rather than the number of machines that
  physically exist. A draining machine has already been paid for and is leaving,
  so counting it against the ceiling would let a scale-in block a scale-out. The
  overshoot this admits is bounded to exactly one machine by the quiescence rule
  below, and it is what lets the Governor answer `{:grow, 1}` by *reclaiming* a
  draining machine (un-cordoning something already booted and joined) instead of
  buying a new one.

  ## Laws

  These hold for every input and are proved in
  `test/hyper/cluster/fleet/policy_properties_test.exs`.

    1. **Band.** `{:grow, 1}` is returned only when the committed count is
       strictly below `max_nodes`; `{:shrink, _}` only when dropping one keeps
       the committed count at or above `min_nodes`.
    2. **Grow and shrink never overlap.** Grow requires `headroom < target`;
       shrink requires `headroom - the candidate's own contribution >= target`.
       Since a contribution is never negative the two conditions are disjoint,
       and no tick can be argued into either direction by both signals.
    3. **No oscillation.** Applying a decision and re-deciding never yields the
       opposite decision. After `{:grow, 1}` the machine is in flight, and a
       fleet with anything in flight never shrinks. After `{:shrink, n}` node
       `n` is draining, which removes exactly the contribution the surplus test
       already subtracted, so the post-state still has `headroom >= target`.
    4. **Quiescence.** `{:shrink, _}` is returned only from a settled fleet:
       nothing in flight and nothing already draining. Capacity in motion is
       capacity not yet measured, and acting twice on one reading is how a
       regulator over-corrects.
    5. **Shrink safety.** The proposed node is never draining, it is always one
       the caller declared drainable, and it is always maximally free among
       those - no other candidate has more free memory (ties broken on free
       disk, then on node name so the choice is a function of the fleet and not
       of list order). In a uniform fleet, free memory is the machine's capacity
       minus what its VMs reserved, so "maximally free" is "reservation-free"
       whenever any reservation-free machine exists.
    6. **Monotone in evidence.** Raising `in_flight` never introduces
       `{:grow, 1}`; adding a fully idle machine to a fleet that already has an
       available one never introduces `{:grow, 1}`; and cordoning a machine
       never withdraws one. More capacity, real or ordered, only ever weakens
       the case for buying more. The single exception is the *blind* fleet:
       while nothing has joined, an outstanding order is credited with the
       whole target, so the first machine to join can be worse evidence than
       the guess it replaces and re-open the case for growing. That is the
       price of not over-ordering during a cold start, and one tick pays it.
    7. **Cold start.** An empty fleet with nothing in flight answers
       `{:grow, 1}` whenever anything is wanted at all (`min_nodes > 0` or
       `target_headroom > 0`), with no estimate required.

  Deliberately **not** a law: "adding a loaded machine never introduces
  `{:shrink, _}`". It can, and correctly so - a fleet that just gained capacity
  can afford to lose its emptiest member even if the machine that arrived is
  busy. Total headroom, not per-node load, is what the decision is about.
  """

  use Unit.Operators

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance
  alias Hyper.Vm.Instance.Spec
  alias Unit.Information

  @typedoc "One machine's worth of change, or nothing."
  @type decision :: {:grow, 1} | {:shrink, node()} | :hold

  @typedoc "Reference instances still placeable on each available node."
  @type slots_by_node :: %{node() => non_neg_integer()}

  @typedoc """
  What the caller can actually act on: the nodes it holds a `:ready` controller
  for (`drainable`) and the nodes it is already emptying (`draining`).

  `:unmanaged` means the caller has no such view, and both questions fall back to
  the advertised `drain` flag: every available node is a candidate, and any
  cordon at all suspends scale-in.
  """
  @type control :: %{drainable: [node()], draining: [node()]} | :unmanaged

  @doc """
  Decide the fleet's next size change from the gossiped node snapshots.

  `states` is `Hyper.Cluster.Budget.all_states/0` - every machine that has
  joined the BEAM cluster. `in_flight` is the number of machines ordered but
  not yet joined, which the Governor knows from its own controllers and the
  snapshots cannot show. `control` is which of those nodes the caller can drain
  and which it is already draining; see `t:control/0`.

  `{:grow, 1}` asks for one more machine's worth of capacity; the Governor may
  satisfy it by reclaiming a draining machine rather than provisioning.
  `{:shrink, node}` names the machine to cordon and drain - never one to
  destroy outright, since VMs cannot migrate.
  """
  @spec decide([NodeState.t()], non_neg_integer(), Config.t(), control()) :: decision()
  def decide(states, in_flight, cfg, control \\ :unmanaged)

  def decide(states, in_flight, %Config{} = cfg, control)
      when is_integer(in_flight) and Kernel.>=(in_flight, 0) do
    spec = Instance.spec(cfg.reference_type)
    available = Enum.reject(states, &draining?/1)
    slots_by_node = Map.new(available, &{&1.node, slots(&1, spec)})
    headroom = Enum.sum(Map.values(slots_by_node)) + pending(in_flight, slots_by_node, cfg)
    committed = length(available) + in_flight

    cond do
      grow?(committed, headroom, cfg) ->
        {:grow, 1}

      quiescent?(states, available, in_flight, control) ->
        shrink(candidates(available, control), slots_by_node, headroom, committed, cfg)

      true ->
        :hold
    end
  end

  @spec candidates([NodeState.t()], control()) :: [NodeState.t()]
  defp candidates(available, :unmanaged), do: available

  defp candidates(available, %{drainable: drainable}) do
    Enum.filter(available, &(&1.node in drainable))
  end

  @spec draining?(NodeState.t()) :: boolean()
  defp draining?(%NodeState{drain: true}), do: true
  defp draining?(%NodeState{}), do: false

  @spec grow?(non_neg_integer(), non_neg_integer(), Config.t()) :: boolean()
  defp grow?(committed, headroom, cfg) do
    under_ceiling?(committed, cfg.max_nodes) and
      (committed < cfg.min_nodes or headroom < cfg.target_headroom)
  end

  @spec under_ceiling?(non_neg_integer(), pos_integer() | nil) :: boolean()
  defp under_ceiling?(_committed, nil), do: true
  defp under_ceiling?(committed, max_nodes), do: committed < max_nodes

  # Scale in only from a settled fleet. An outstanding order or a drain already
  # under way is capacity whose effect has not been measured yet, and the whole
  # point of a one-machine-at-a-time regulator is that it waits to see. A machine
  # merely cordoned is *not* capacity in motion - nothing is going to happen to
  # it - so it suspends nothing when the caller can tell the two apart.
  @spec quiescent?([NodeState.t()], [NodeState.t()], non_neg_integer(), control()) :: boolean()
  defp quiescent?(states, available, in_flight, :unmanaged) do
    in_flight == 0 and length(states) == length(available)
  end

  defp quiescent?(_states, _available, in_flight, %{draining: draining}) do
    in_flight == 0 and draining == []
  end

  @spec shrink(
          [NodeState.t()],
          slots_by_node(),
          non_neg_integer(),
          non_neg_integer(),
          Config.t()
        ) :: {:shrink, node()} | :hold
  defp shrink(candidates, slots_by_node, headroom, committed, cfg) do
    case emptiest(candidates) do
      nil -> :hold
      state -> propose(state, headroom - Map.fetch!(slots_by_node, state.node), committed, cfg)
    end
  end

  @spec propose(NodeState.t(), integer(), non_neg_integer(), Config.t()) ::
          {:shrink, node()} | :hold
  defp propose(state, headroom_without, committed, cfg) do
    if headroom_without >= cfg.target_headroom and committed - 1 >= cfg.min_nodes do
      {:shrink, state.node}
    else
      :hold
    end
  end

  @spec emptiest([NodeState.t()]) :: NodeState.t() | nil
  defp emptiest([]), do: nil
  defp emptiest(states), do: Enum.min_by(states, &emptiness/1)

  # Most free memory wins, then most free disk, then the node name. Memory is
  # first because it is the dimension that binds in practice; the name is last
  # so the choice depends on the fleet and not on the order Horde happened to
  # hand the snapshots over in.
  @spec emptiness(NodeState.t()) :: {integer(), integer(), node()}
  defp emptiness(state) do
    {-Information.as_bytes(state.mem_free), -Information.as_bytes(state.disk_free), state.node}
  end

  @spec pending(non_neg_integer(), slots_by_node(), Config.t()) :: non_neg_integer()
  defp pending(0, _slots_by_node, _cfg), do: 0

  # Nothing has joined, so there is no evidence of what a machine of this shape
  # provides. Credit the outstanding order with the whole target rather than
  # ordering a second machine against the same shortage; the next tick decides
  # on measurement instead of on a guess.
  defp pending(_in_flight, slots_by_node, cfg) when map_size(slots_by_node) == 0 do
    cfg.target_headroom
  end

  defp pending(in_flight, slots_by_node, _cfg) do
    in_flight * Enum.max(Map.values(slots_by_node))
  end

  @spec slots(NodeState.t(), Spec.t()) :: non_neg_integer()
  defp slots(state, spec), do: fill(state, spec, fill_bound(state, spec), 0)

  @spec fill(NodeState.t(), Spec.t(), integer(), non_neg_integer()) :: non_neg_integer()
  defp fill(_state, _spec, bound, placed) when Kernel.<=(bound, 0), do: placed

  defp fill(state, spec, bound, placed) do
    if NodeState.fits?(state, spec) do
      fill(place(state, spec), spec, bound - 1, placed + 1)
    else
      placed
    end
  end

  # Memory is the dimension every simulated placement strictly consumes, so the
  # number of times the spec's memory divides free memory terminates the fill.
  # Every `Hyper.Vm.Instance` type demands memory; a spec that demanded none
  # would fit forever, so it is given no budget rather than looped on.
  @spec fill_bound(NodeState.t(), Spec.t()) :: integer()
  defp fill_bound(state, spec) do
    case Information.as_bytes(spec.mem) do
      0 -> 0
      demand -> div(Information.as_bytes(state.mem_free), demand)
    end
  end

  # One simulated placement against the snapshot.
  @spec place(NodeState.t(), Spec.t()) :: NodeState.t()
  defp place(state, spec) do
    %{
      state
      | mem_free: state.mem_free - spec.mem,
        disk_free: state.disk_free - spec.disk,
        cpu_load: state.cpu_load + spec.vcpus / state.cpu_capacity,
        disk_bw_load: state.disk_bw_load + spec.disk_bw,
        net_bw_load: state.net_bw_load + spec.net_bw
    }
  end
end
