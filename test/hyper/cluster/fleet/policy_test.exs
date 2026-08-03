defmodule Hyper.Cluster.Fleet.PolicyTest do
  @moduledoc """
  The cases `Hyper.Cluster.Fleet.PolicyPropertiesTest` cannot express, because
  they need a fleet whose dimensions disagree rather than a uniform one:

    * the placeable count is the minimum across every dimension `fits?/2`
      checks, including the soft ones, and it counts *repeated* placements
      rather than "does one fit";
    * a machine in flight is valued at the emptiest joined machine's count, and
      at the whole target when nothing has joined to measure;
    * only a node the caller says it can drain is ever proposed for draining,
      and a machine merely cordoned does not suspend scale-in the way one
      actually leaving does;
    * `max_nodes` bounds the machines the fleet means to keep, so a drain in
      progress cannot block a scale-out;
    * the exact boundary at which surplus becomes a scale-in, and the
      `min_nodes` floor that overrides it.
  """
  use ExUnit.Case, async: true

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Cluster.Fleet.Policy
  alias Hyper.Cluster.Fleet.Provider
  alias Hyper.Node.Budget.NodeState
  alias Unit.Bandwidth
  alias Unit.Information
  alias Unit.Time

  # The `:base` reference instance is 4 vCPU / 2 GiB / 32 GiB / 256 MiBps disk
  # / 128 MiBps net. Each row starves exactly one dimension and states how many
  # whole reference instances the node can then take.
  @dimension_rows [
    {"free memory", [mem: Information.gib(6)], 3},
    {"free disk", [disk: Information.gib(64)], 2},
    {"cpu load ceiling", [cpu_capacity: 8], 2},
    {"disk bandwidth ceiling", [disk_bw_ceiling: Bandwidth.mibps(768)], 3},
    {"an already saturated cpu", [cpu_capacity: 8, cpu_load: 0.9], 0}
  ]

  test "the placeable count is the minimum over every dimension the fit check binds on" do
    for {dimension, opts, placeable} <- @dimension_rows do
      node = machine(:n@h, opts)

      assert Policy.decide([node], 0, cfg(target_headroom: placeable)) == :hold,
             "bound by #{dimension}: expected #{placeable} placeable, found fewer"

      assert Policy.decide([node], 0, cfg(target_headroom: placeable + 1)) == {:grow, 1},
             "bound by #{dimension}: expected #{placeable} placeable, found more"
    end
  end

  describe "machines in flight" do
    test "are valued at the emptiest joined machine's placeable count" do
      # One joined machine with room for two more reference instances, plus one
      # ordered: four instances' worth of headroom, not two.
      joined = machine(:n@h, mem: Information.gib(4))

      assert Policy.decide([joined], 1, cfg(min_nodes: 0, target_headroom: 3)) == :hold
      assert Policy.decide([joined], 1, cfg(min_nodes: 0, target_headroom: 4)) == :hold
      assert Policy.decide([joined], 1, cfg(min_nodes: 0, target_headroom: 5)) == {:grow, 1}
    end

    # A uniform fleet's machines are the same shape, so the emptiest joined one
    # is the closest thing to a measurement of what a *fresh* one provides —
    # and, since no joined node can be emptier than a fresh one, a lower bound.
    # Valuing an order at the fullest node (or an average) would keep signalling
    # a shortage that has already been answered.
    test "are valued at the emptiest of several, not the fullest" do
      saturated = machine(:full@h, mem: Information.gib(1))
      roomy = machine(:roomy@h, mem: Information.gib(4))
      fleet = [saturated, roomy]

      # 0 + 2 placeable now, plus one order worth the roomy machine's 2.
      assert Policy.decide(fleet, 1, cfg(min_nodes: 0, target_headroom: 4)) == :hold
      assert Policy.decide(fleet, 1, cfg(min_nodes: 0, target_headroom: 5)) == {:grow, 1}
    end

    test "are credited the whole target while nothing has joined to measure" do
      assert Policy.decide([], 1, cfg(min_nodes: 0, target_headroom: 5)) == :hold
      assert Policy.decide([], 0, cfg(min_nodes: 0, target_headroom: 5)) == {:grow, 1}
    end
  end

  describe "max_nodes" do
    test "does not count a machine that is already draining" do
      states = [machine(:a@h, mem: Information.gib(4)), machine(:b@h, drain: true)]
      full = [machine(:a@h, mem: Information.gib(4)), machine(:b@h, mem: Information.gib(4))]
      short = cfg(min_nodes: 0, max_nodes: 2, target_headroom: 10)

      assert Policy.decide(states, 0, short) == {:grow, 1}
      assert Policy.decide(full, 0, short) == :hold
    end
  end

  describe "scale-in" do
    setup do
      # Two interchangeable idle machines, two reference instances each.
      {:ok,
       states: [machine(:a@h, mem: Information.gib(4)), machine(:b@h, mem: Information.gib(4))]}
    end

    test "fires exactly when the fleet keeps its target without the emptiest machine", %{
      states: states
    } do
      assert Policy.decide(states, 0, cfg(min_nodes: 0, target_headroom: 2)) == {:shrink, :a@h}
      assert Policy.decide(states, 0, cfg(min_nodes: 0, target_headroom: 3)) == :hold
    end

    test "is refused at the min_nodes floor", %{states: states} do
      for {min_nodes, expected} <- [{0, {:shrink, :a@h}}, {1, {:shrink, :a@h}}, {2, :hold}] do
        assert Policy.decide(states, 0, cfg(min_nodes: min_nodes, target_headroom: 0)) == expected,
               "min_nodes #{min_nodes}"
      end
    end
  end

  # A node the caller cannot drain is a node it must not be told to drain: an
  # unmanaged machine that happens to be the emptiest in the cluster would
  # otherwise be named every tick and refused every tick, and the fleet could
  # never shrink at all.
  @drainable_rows [
    {"with no view, the emptiest node in the fleet", :unmanaged, {:shrink, :b@h}},
    {"with a view, the emptiest *drainable* node", %{drainable: [:a@h], draining: []},
     {:shrink, :a@h}},
    {"with nothing drainable, nothing", %{drainable: [], draining: []}, :hold}
  ]

  describe "what the caller can act on" do
    test "the shrink candidate is the emptiest node the caller says it can drain" do
      fleet = [machine(:a@h, mem: Information.gib(8)), machine(:b@h, mem: Information.gib(64))]

      for {desc, control, expected} <- @drainable_rows do
        assert Policy.decide(fleet, 0, cfg(min_nodes: 0, target_headroom: 0), control) ==
                 expected,
               desc
      end
    end

    # Being cordoned and being on the way out are different things, and only the
    # second is capacity in motion. Conflating them means one machine an
    # operator parked for a kernel upgrade blocks every scale-in in the cluster
    # until they come back.
    @quiescence_rows [
      {"any cordon at all, when they cannot be told apart", :unmanaged, :hold},
      {"a cordon nobody is draining", %{drainable: [:a@h], draining: []}, {:shrink, :a@h}},
      {"a drain already under way", %{drainable: [:a@h], draining: [:b@h]}, :hold}
    ]

    test "scale-in waits for the fleet to settle" do
      fleet = [machine(:a@h, mem: Information.gib(8)), machine(:b@h, drain: true)]

      for {desc, control, expected} <- @quiescence_rows do
        assert Policy.decide(fleet, 0, cfg(min_nodes: 0, target_headroom: 0), control) ==
                 expected,
               desc
      end
    end
  end

  defp machine(name, opts) do
    %NodeState{
      node: name,
      mem_free: Keyword.get(opts, :mem, Information.gib(1024)),
      disk_free: Keyword.get(opts, :disk, Information.tib(100)),
      cpu_load: Keyword.get(opts, :cpu_load, 0.0),
      cpu_capacity: Keyword.get(opts, :cpu_capacity, 4096),
      cpu_max_load: 1.0,
      disk_bw_load: Bandwidth.zero(),
      disk_bw_ceiling: Keyword.get(opts, :disk_bw_ceiling, Bandwidth.tibps(1)),
      net_bw_load: Bandwidth.zero(),
      net_bw_ceiling: Bandwidth.tibps(1),
      layers: [],
      drain: Keyword.get(opts, :drain, false)
    }
  end

  # `min_nodes: 1` by default so a single-node fleet is never a shrink
  # candidate: the dimension table is about the capacity signal alone.
  defp cfg(overrides) do
    struct!(
      %Config{
        provider: Provider.Static,
        provider_opts: [],
        min_nodes: 1,
        max_nodes: nil,
        target_headroom: 1,
        reference_type: :base,
        cooldown: Time.s(120),
        provision_deadline: Time.s(600),
        nodedown_grace: Time.s(300),
        drain_deadline: Time.s(1800)
      },
      overrides
    )
  end
end
