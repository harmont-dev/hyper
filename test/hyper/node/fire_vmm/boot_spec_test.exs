defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.BootSpec

  test "default cmdline boots our agent as init with no serial console" do
    source = %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs"}
    cold = BootSpec.resolve(source, :micro)
    assert cold.boot_source.boot_args =~ "init=/hyper-init"
    # No console by default: serial printk blocks the boot vCPU. A debug boot
    # re-adds console=ttyS0 through the per-VM boot_args override.
    refute cold.boot_source.boot_args =~ "console="
  end
end
