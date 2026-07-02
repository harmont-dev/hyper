defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.BootSpec

  test "default cmdline boots our agent as init" do
    source = %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs"}
    cold = BootSpec.resolve(source, :micro)
    assert cold.boot_source.boot_args =~ "init=/hyper-init"
    assert cold.boot_source.boot_args =~ "console=ttyS0"
  end
end
