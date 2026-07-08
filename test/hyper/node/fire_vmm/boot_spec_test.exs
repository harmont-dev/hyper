defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.BootSpec

  # The enabled path (NIC populated + `ip=` appended) needs a `[network]` config
  # override, which the unit config harness doesn't provide; it's asserted in
  # the e2e/integration suite instead. This module only pins the disabled path
  # (the base test config has no `[network]` table), which must hold for every
  # existing VM.

  test "default cmdline boots our agent as init with no serial console" do
    source = %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs"}
    cold = BootSpec.resolve(source, :micro)
    assert cold.boot_source.boot_args =~ "init=/hyper-init"
    # No console by default: serial printk blocks the boot vCPU. A debug boot
    # re-adds console=ttyS0 through the per-VM boot_args override.
    refute cold.boot_source.boot_args =~ "console="
  end

  test "no NIC and no ip= when networking disabled" do
    source = %{vm_id: "vabc", kernel_image_path: "/vmlinux", root_drive_path: "/rootfs"}
    cold = BootSpec.resolve(source, :micro)
    assert cold.network_interfaces == []
    refute cold.boot_source.boot_args =~ "ip="
  end
end
