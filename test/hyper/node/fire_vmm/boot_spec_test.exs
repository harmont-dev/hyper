defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true
  alias Hyper.Node.FireVMM.BootSpec

  test "jailify rewrites kernel and rootfs paths to jail-relative" do
    source = %{
      kernel_image_path: "/srv/hyper/vmlinux/vmlinux-x86_64",
      root_drive_path: "/dev/mapper/hyper-rw-vm1"
    }

    cold = BootSpec.resolve(source, :base)
    jailed = BootSpec.jailify(cold, "/vmlinux", "/rootfs")

    assert jailed.boot_source.kernel_image_path == "/vmlinux"
    assert [%{drive_id: "rootfs", path_on_host: "/rootfs"}] = jailed.drives
  end
end
