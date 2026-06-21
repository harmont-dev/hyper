defmodule Hyper.Vm.Instance.SpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Vm.Instance
  alias Hyper.Vm.Instance.Spec

  describe "vcpu_count/1" do
    test "rounds a fractional cgroup quota up to a positive integer" do
      # :micro is 0.25 vCPU, :milli is 0.5 - both must present at least 1 to the guest.
      assert Spec.vcpu_count(Instance.spec(:micro)) == 1
      assert Spec.vcpu_count(Instance.spec(:milli)) == 1
    end

    test "passes whole vCPU counts through" do
      assert Spec.vcpu_count(Instance.spec(:centi)) == 1
      assert Spec.vcpu_count(Instance.spec(:deci)) == 2
      assert Spec.vcpu_count(Instance.spec(:base)) == 4
    end
  end

  describe "mem_mib/1" do
    test "expresses the spec's memory in MiB" do
      assert Spec.mem_mib(Instance.spec(:micro)) == 128
      assert Spec.mem_mib(Instance.spec(:base)) == 2048
    end
  end
end
