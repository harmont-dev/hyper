defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.BootSpec
  alias Hyper.Node.Net.Ip
  alias Hyper.Vm.Instance
  alias Unit.Bandwidth

  @host %Ip.Host{
    uplink: "if0",
    transit_prefix: {{10, 200, 0, 0}, 16},
    vm_prefix: {{0x2001, 0xDB8, 0, 0, 1, 0, 0, 0}, 80}
  }

  @lease Ip.lease(@host, 64)

  @source %{
    vm_id: "vbootspec",
    net: @lease,
    kernel_image_path: "/vmlinux",
    root_drive_path: "/rootfs"
  }

  test "default cmdline boots our agent as init with no serial console" do
    cold = BootSpec.resolve(@source, :micro)
    assert cold.boot_source.boot_args =~ "init=/hyper-init"
    # No console by default: serial printk blocks the boot vCPU. A debug boot
    # re-adds console=ttyS0 through the per-VM boot_args override.
    refute cold.boot_source.boot_args =~ "console="
  end

  test "every VM boots with its IP config on the cmdline, overridden boot_args or not" do
    for source <- [@source, Map.put(@source, :boot_args, "console=ttyS0")] do
      args = BootSpec.resolve(source, :micro).boot_source.boot_args |> String.split(" ")

      assert Enum.all?(Ip.guest_args(@lease), &(&1 in args)), inspect(args)
    end
  end

  test "every instance type's NIC is capped at its net_bw in both directions" do
    for type <- Instance.types() do
      bytes_per_sec =
        type |> Instance.spec() |> Map.fetch!(:net_bw) |> Bandwidth.as_bytes_per_sec()

      [nic] = BootSpec.resolve(@source, type).network_interfaces

      for limiter <- [nic.rx_rate_limiter, nic.tx_rate_limiter] do
        %{size: size, refill_time: refill_ms} = limiter.bandwidth
        assert div(size * 1000, refill_ms) == bytes_per_sec, inspect({type, limiter})
      end
    end
  end

  test "every VM boots with one NIC, guest eth0 on the namespace's tap0" do
    assert [%{iface_id: "eth0", host_dev_name: "tap0"}] =
             BootSpec.resolve(@source, :micro).network_interfaces
  end
end
