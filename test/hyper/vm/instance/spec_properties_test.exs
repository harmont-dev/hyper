defmodule Hyper.Vm.Instance.SpecPropertiesTest do
  @moduledoc """
  Laws of a spec's host memory: the VM cgroup's `memory.high` is exactly
  `host_mem/1`, the figure the node budget reserves, and it strictly exceeds
  the guest's RAM; `memory.max` strictly exceeds `memory.high`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Vm.Instance
  alias Hyper.Vm.Instance.Spec
  alias Unit.Information

  defp spec do
    one_of([
      map(member_of(Instance.types()), &Instance.spec/1),
      map(integer(1..1_048_576), &%{Instance.spec(:micro) | mem: Information.mib(&1)})
    ])
  end

  property "memory.high is the budgeted host_mem, above guest RAM and below memory.max" do
    check all(spec <- spec()) do
      cgroup = Spec.cgroup_v2(spec)

      assert cgroup.memory_high == Information.as_bytes(Spec.host_mem(spec))
      assert cgroup.memory_high > Information.as_bytes(spec.mem)
      assert cgroup.memory_max > cgroup.memory_high
    end
  end
end
