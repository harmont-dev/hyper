defmodule Hyper.Node.Budget.NodeStatePropertiesTest do
  @moduledoc """
  Monotonicity laws of the pure `NodeState.fits?/2` predicate, complementing the
  exact-`<=`-boundary example tests. A spec strictly within every ceiling always
  fits, exceeding free memory always fails, and a spec that fits a node still
  fits a node with strictly more headroom.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Unit.Operators

  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  # A node, idle on every soft metric with `cpu_max_load` at 1.0, so the only
  # binding limits are the generated hard headrooms and cpu capacity.
  defp state do
    gen all(
          mem_gib <- integer(1..64),
          disk_gib <- integer(1..1000),
          cpu_cap <- integer(1..128)
        ) do
      %NodeState{
        node: :n@h,
        mem_free: Information.gib(mem_gib),
        disk_free: Information.gib(disk_gib),
        cpu_load: 0.0,
        cpu_capacity: cpu_cap,
        cpu_max_load: 1.0,
        disk_bw_load: Bandwidth.zero(),
        disk_bw_ceiling: Bandwidth.gibps(10),
        net_bw_load: Bandwidth.zero(),
        net_bw_ceiling: Bandwidth.gibps(10),
        layers: []
      }
    end
  end

  # A spec whose demand sits within every ceiling of `st`.
  defp fitting_spec(st) do
    gen all(
          mem_gib <- integer(0..Information.as_gib(st.mem_free)),
          disk_gib <- integer(0..Information.as_gib(st.disk_free)),
          vcpus <- integer(0..st.cpu_capacity)
        ) do
      %Spec{
        vcpus: vcpus,
        mem: Information.gib(mem_gib),
        disk: Information.gib(disk_gib),
        disk_bw: Bandwidth.zero(),
        net_bw: Bandwidth.zero()
      }
    end
  end

  property "a spec within every ceiling always fits" do
    check all(st <- state(), spec <- fitting_spec(st)) do
      assert NodeState.fits?(st, spec)
    end
  end

  property "exceeding free memory always fails" do
    check all(st <- state(), over <- integer(1..1000)) do
      spec = %Spec{
        vcpus: 0,
        mem: st.mem_free + Information.gib(over),
        disk: Information.zero(),
        disk_bw: Bandwidth.zero(),
        net_bw: Bandwidth.zero()
      }

      refute NodeState.fits?(st, spec)
    end
  end

  property "a fitting spec still fits when the node gains headroom" do
    check all(st <- state(), spec <- fitting_spec(st), extra <- integer(0..100)) do
      roomier = %{
        st
        | mem_free: st.mem_free + Information.gib(extra),
          disk_free: st.disk_free + Information.gib(extra)
      }

      # Precondition the law on the spec actually fitting `st`.
      if NodeState.fits?(st, spec), do: assert(NodeState.fits?(roomier, spec))
    end
  end
end
