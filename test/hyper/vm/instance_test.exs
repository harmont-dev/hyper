defmodule Hyper.Vm.InstanceTest do
  use ExUnit.Case, async: true

  alias Hyper.Vm.Instance
  alias Unit.{Bandwidth, Information}

  test "tall is memory-optimized without increasing the deci disk reservation" do
    assert %Instance.Spec{
             vcpus: 3,
             mem: mem,
             disk: disk,
             disk_bw: disk_bw,
             net_bw: net_bw
           } = Instance.spec(:tall)

    assert Information.as_mib(mem) == 4_096
    assert Information.as_gib(disk) == 16
    assert disk_bw == Bandwidth.mibps(128)
    assert net_bw == Bandwidth.mibps(64)
  end

  test "tall exposes all three vCPUs and four GiB to the guest" do
    config = :tall |> Instance.spec() |> Instance.Spec.machine_config()

    assert config.vcpu_count == 3
    assert config.mem_size_mib == 4_096
  end

  test "the host cgroup leaves room for Firecracker outside guest memory" do
    cgroup = :tall |> Instance.spec() |> Instance.Spec.cgroup_v2()

    assert cgroup.memory_max == Information.mib(4_352) |> Information.as_bytes()
  end
end
