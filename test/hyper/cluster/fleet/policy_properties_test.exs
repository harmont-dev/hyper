defmodule Hyper.Cluster.Fleet.PolicyPropertiesTest do
  @moduledoc """
  The laws `Hyper.Cluster.Fleet.Policy.decide/3` claims, proved over generated
  fleets. Silent arithmetic bugs here cost real money, so every branch of the
  decision is pinned by an invariant rather than by an example:

    * **Band** - a decision never takes the committed fleet outside
      `[min_nodes, max_nodes]`.
    * **No oscillation** - applying a decision and re-deciding never yields the
      opposite decision, in either direction.
    * **Quiescence** - scale-in is refused whenever a machine is in flight or a
      drain is already under way.
    * **Shrink safety** - the proposed node is available and maximally free,
      and while any reservation-free machine exists it is one of those.
    * **Order independence** - the same fleet in a different order is the same
      decision, ties included.
    * **Monotone in evidence** - neither an extra idle machine nor a higher
      `in_flight` ever introduces a grow, and cordoning a machine never
      withdraws one.
    * **Headroom oracle** - the grow signal is exactly "fewer reference
      instances are placeable than `target_headroom`", counted independently of
      the implementation's fill loop.
    * **Cold start** - an empty fleet grows whenever anything is wanted at all.

  The fleet is modelled the way the design assumes it: one machine shape shared
  by every node, so a node's free memory is its capacity minus what its VMs
  reserved, expressed in whole reference instances.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Cluster.Fleet.Policy
  alias Hyper.Cluster.Fleet.Provider
  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance
  alias Unit.Bandwidth
  alias Unit.Information
  alias Unit.Quantity
  alias Unit.Time

  @reference :base
  @ref_spec Instance.spec(@reference)

  # Large enough that no soft metric ever binds for the fleet sizes generated
  # here, so a node's placeable count is exactly its unreserved capacity.
  @cpu_capacity 4096
  @bw_ceiling Bandwidth.tibps(1)

  @max_capacity 6
  @max_nodes 5

  property "a decision never takes the committed fleet outside [min_nodes, max_nodes]" do
    check all(
            {_capacity, states} <- fleet(),
            in_flight <- integer(0..3),
            cfg <- config()
          ) do
      committed = Enum.count(states, &(not &1.drain)) + in_flight

      case Policy.decide(states, in_flight, cfg) do
        {:grow, 1} -> assert is_nil(cfg.max_nodes) or committed < cfg.max_nodes
        {:shrink, _node} -> assert committed - 1 >= cfg.min_nodes
        :hold -> :ok
      end
    end
  end

  property "growing never makes the next tick shrink" do
    check all(
            {_capacity, states} <- fleet(),
            in_flight <- integer(0..3),
            cfg <- config()
          ) do
      if Policy.decide(states, in_flight, cfg) == {:grow, 1} do
        refute match?({:shrink, _node}, Policy.decide(states, in_flight + 1, cfg))
      end
    end
  end

  property "shrinking never makes the next tick grow" do
    check all({_capacity, states} <- fleet(), cfg <- config()) do
      case Policy.decide(states, 0, cfg) do
        {:shrink, node} ->
          refute Policy.decide(cordon(states, node), 0, cfg) == {:grow, 1}

        _other ->
          :ok
      end
    end
  end

  property "scale-in is refused unless the fleet is settled" do
    check all(
            {_capacity, states} <- fleet(),
            in_flight <- integer(0..3),
            cfg <- config()
          ) do
      settled? = in_flight == 0 and not Enum.any?(states, & &1.drain)
      shrinking? = match?({:shrink, _node}, Policy.decide(states, in_flight, cfg))

      assert settled? or not shrinking?,
             "proposed a scale-in from a fleet with capacity still in motion"
    end
  end

  property "the shrunk node is available and maximally free" do
    check all({_capacity, states} <- fleet(), cfg <- config()) do
      case Policy.decide(states, 0, cfg) do
        {:shrink, node} ->
          available = Enum.reject(states, & &1.drain)
          chosen = Enum.find(available, &(&1.node == node))

          assert chosen, "cordoned #{node}, which is not an available node"
          assert free_units(chosen) == available |> Enum.map(&free_units/1) |> Enum.max()

        _other ->
          :ok
      end
    end
  end

  property "a machine holding reservations is never cordoned while an idle one exists" do
    check all({capacity, states} <- fleet_with_idle_machine(), cfg <- config()) do
      case Policy.decide(states, 0, cfg) do
        {:shrink, node} ->
          chosen = Enum.find(states, &(&1.node == node))
          assert free_units(chosen) == capacity

        _other ->
          :ok
      end
    end
  end

  property "raising in_flight never introduces a grow" do
    check all(
            {_capacity, states} <- fleet(),
            in_flight <- integer(0..3),
            cfg <- config()
          ) do
      if Policy.decide(states, in_flight + 1, cfg) == {:grow, 1} do
        assert Policy.decide(states, in_flight, cfg) == {:grow, 1}
      end
    end
  end

  property "adding an idle machine to a fleet that already has one never introduces a grow" do
    check all(
            {capacity, states} <- fleet_with_available_machine(),
            in_flight <- integer(0..3),
            cfg <- config()
          ) do
      grown = [machine(:fresh@h, capacity, 0, false) | states]

      if Policy.decide(grown, in_flight, cfg) == {:grow, 1} do
        assert Policy.decide(states, in_flight, cfg) == {:grow, 1}
      end
    end
  end

  # With nothing in flight there is no per-machine estimate in play, so this is
  # purely "a draining machine's capacity does not count": losing one can only
  # strengthen the case for growing.
  property "cordoning a machine never withdraws a pending grow" do
    check all(
            {_capacity, states} <- fleet(min_length: 1),
            index <- integer(0..(@max_nodes - 1)),
            cfg <- config()
          ) do
      victim = Enum.at(states, rem(index, length(states)))

      if Policy.decide(states, 0, cfg) == {:grow, 1} do
        assert Policy.decide(cordon(states, victim.node), 0, cfg) == {:grow, 1}
      end
    end
  end

  property "grow is exactly the shortfall of placeable reference instances" do
    check all({_capacity, states} <- fleet(), cfg <- config()) do
      # Neither bound may interfere: this law is about the capacity signal alone.
      unbanded = %{cfg | min_nodes: 0, max_nodes: nil}

      placeable =
        states
        |> Enum.reject(& &1.drain)
        |> Enum.map(&free_units/1)
        |> Enum.sum()

      grew? = Policy.decide(states, 0, unbanded) == {:grow, 1}

      assert grew? == placeable < unbanded.target_headroom
    end
  end

  # `Hyper.Cluster.Budget.all_states/0` reads a CRDT replica, whose order is
  # neither stable across nodes nor across ticks. A decision that depended on it
  # would have two Governors mid-handover cordon two different machines for a
  # one-machine surplus — which is what the node-name tie-break in `emptiness/1`
  # exists to prevent.
  property "the decision is a function of the fleet, not of the order it arrives in" do
    check all(
            {_capacity, states} <- fleet(),
            in_flight <- integer(0..3),
            cfg <- config()
          ) do
      assert Policy.decide(Enum.shuffle(states), in_flight, cfg) ==
               Policy.decide(states, in_flight, cfg)
    end
  end

  property "an empty fleet grows whenever anything is wanted" do
    check all(cfg <- config()) do
      wanted? = cfg.min_nodes > 0 or cfg.target_headroom > 0
      expected = if wanted?, do: {:grow, 1}, else: :hold

      assert Policy.decide([], 0, cfg) == expected
    end
  end

  # A uniform fleet: one machine shape (`capacity` reference instances), each
  # node having reserved some of it and possibly already draining.
  defp fleet(opts \\ []) do
    gen all(
          capacity <- integer(0..@max_capacity),
          nodes <-
            list_of(tuple({integer(0..capacity), boolean()}),
              min_length: Keyword.get(opts, :min_length, 0),
              max_length: @max_nodes
            )
        ) do
      {capacity, build(capacity, nodes)}
    end
  end

  # The same fleet, guaranteed to contain at least one machine that has joined
  # and is not draining, so the policy has some evidence of the machine shape.
  defp fleet_with_available_machine do
    gen all(
          capacity <- integer(0..@max_capacity),
          used <- integer(0..capacity),
          others <- list_of(tuple({integer(0..capacity), boolean()}), max_length: @max_nodes - 1),
          position <- integer(0..length(others))
        ) do
      {capacity, build(capacity, List.insert_at(others, position, {used, false}))}
    end
  end

  # The same fleet, guaranteed to contain at least one machine that is idle and
  # cordonable - the precondition of the reservation-safety law.
  defp fleet_with_idle_machine do
    gen all(
          capacity <- integer(1..@max_capacity),
          others <- list_of(tuple({integer(0..capacity), boolean()}), max_length: @max_nodes - 1),
          position <- integer(0..length(others))
        ) do
      {capacity, build(capacity, List.insert_at(others, position, {0, false}))}
    end
  end

  defp build(capacity, nodes) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {{used, drain}, i} -> machine(:"n#{i}@h", capacity, used, drain) end)
  end

  defp machine(name, capacity, used, drain) do
    free = capacity - used

    %NodeState{
      node: name,
      mem_free: times(@ref_spec.mem, free),
      disk_free: times(@ref_spec.disk, free),
      cpu_load: 0.0,
      cpu_capacity: @cpu_capacity,
      cpu_max_load: 1.0,
      disk_bw_load: Bandwidth.zero(),
      disk_bw_ceiling: @bw_ceiling,
      net_bw_load: Bandwidth.zero(),
      net_bw_ceiling: @bw_ceiling,
      layers: [],
      drain: drain
    }
  end

  # The oracle: unreserved capacity in whole reference instances, read back off
  # the snapshot without going near the policy's fill loop.
  defp free_units(state) do
    div(Information.as_bytes(state.mem_free), Information.as_bytes(@ref_spec.mem))
  end

  defp cordon(states, node) do
    Enum.map(states, fn state ->
      if state.node == node, do: %{state | drain: true}, else: state
    end)
  end

  defp times(quantity, n), do: Quantity.with_value(quantity, Quantity.value(quantity) * n)

  defp config do
    gen all(
          min_nodes <- integer(0..4),
          span <- one_of([constant(nil), integer(0..4)]),
          target_headroom <- integer(0..8)
        ) do
      %Config{
        provider: Provider.Static,
        provider_opts: [],
        min_nodes: min_nodes,
        max_nodes: ceiling(min_nodes, span),
        target_headroom: target_headroom,
        reference_type: @reference,
        cooldown: Time.s(120),
        provision_deadline: Time.s(600),
        nodedown_grace: Time.s(300),
        drain_deadline: Time.s(1800)
      }
    end
  end

  # `max_nodes` is a `pos_integer() | nil` that `Hyper.Cfg.Fleet` validates to be
  # at least `min_nodes`; generate it as an offset so both hold by construction.
  defp ceiling(_min_nodes, nil), do: nil
  defp ceiling(min_nodes, span), do: max(1, min_nodes + span)
end
