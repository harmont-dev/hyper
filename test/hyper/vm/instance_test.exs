defmodule Hyper.Vm.InstanceTest do
  use ExUnit.Case, async: true

  alias Hyper.Vm.Instance
  alias Unit.{Bandwidth, Information}

  test "tall is memory-optimized without increasing the deci disk reservation" do
    deci = Instance.spec(:deci)

    assert %Instance.Spec{
             vcpus: 3,
             mem: mem,
             disk: disk,
             disk_bw: disk_bw,
             net_bw: net_bw
           } = Instance.spec(:tall)

    assert Information.as_mib(mem) == 4_096
    assert Information.as_gib(disk) == 16
    assert disk == deci.disk
    assert disk_bw == Bandwidth.mibps(128)
    assert disk_bw == deci.disk_bw
    assert net_bw == Bandwidth.mibps(64)
    assert net_bw == deci.net_bw
  end

  test "tall exposes all three vCPUs and four GiB to the guest" do
    spec = Instance.spec(:tall)
    config = Instance.Spec.machine_config(spec)
    cgroup = Instance.Spec.cgroup_v2(spec)

    assert config.vcpu_count == 3
    assert config.mem_size_mib == 4_096
    assert cgroup.memory_max == Information.mib(4_096) |> Information.as_bytes()
  end

  test "builder keeps tall's CPU and disk while doubling its memory" do
    tall = Instance.spec(:tall)
    spec = Instance.spec(:builder)
    config = Instance.Spec.machine_config(spec)
    cgroup = Instance.Spec.cgroup_v2(spec)

    assert spec.vcpus == 3
    assert spec.disk == tall.disk
    assert spec.disk_bw == tall.disk_bw
    assert spec.net_bw == tall.net_bw
    assert config.vcpu_count == 3
    assert config.mem_size_mib == 8_192
    assert cgroup.memory_max == Information.mib(8_192) |> Information.as_bytes()
  end
end
