defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.BootSpec

  # Networking is mandatory: every VM gets a NIC plus the kernel
  # `ip=`/`hyper.resolver=` cmdline, derived entirely from the vm_id and the
  # uniform inner world (no `[network]` config needed — the base test config
  # has none). The pure formatting of those fragments is pinned in net_test.exs;
  # this module pins that resolve/2 always emits them.
  @source %{vm_id: "vabc", kernel_image_path: "/vmlinux", root_drive_path: "/rootfs"}

  test "default cmdline boots our agent as init with no serial console" do
    cold = BootSpec.resolve(@source, :micro)
    assert cold.boot_source.boot_args =~ "init=/hyper-init"
    # No console by default: serial printk blocks the boot vCPU. A debug boot
    # re-adds console=ttyS0 through the per-VM boot_args override.
    refute cold.boot_source.boot_args =~ "console="
  end

  test "every VM gets a NIC and the ip=/hyper.resolver= cmdline" do
    cold = BootSpec.resolve(@source, :micro)
    assert length(cold.network_interfaces) == 1
    assert cold.boot_source.boot_args =~ "ip="
    assert cold.boot_source.boot_args =~ "hyper.resolver="
  end
end
