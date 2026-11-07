defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.BootSpec

  @source %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs"}

  test "default cmdline boots our agent as init with no serial console" do
    cold = BootSpec.resolve(@source, :micro)
    assert cold.boot_source.boot_args =~ "init=/hyper-init"
    # No console by default: serial printk blocks the boot vCPU. A debug boot
    # re-adds console=ttyS0 through the per-VM boot_args override.
    refute cold.boot_source.boot_args =~ "console="
  end

  test "a VM boots with no NIC-related kernel cmdline" do
    cold = BootSpec.resolve(@source, :micro)
    refute cold.boot_source.boot_args =~ "ip="
    refute cold.boot_source.boot_args =~ "hyper.resolver="
  end
end
