defmodule Hyper.NodeTest do
  use ExUnit.Case, async: true

  test "build_opts wires uid/gid + jail-bound source" do
    params = %{vm_id: "vm1", img_id: "img1", type: :base, arch: :x86_64, boot_args: nil}

    opts =
      Hyper.Node.build_opts(params, 900_000, "/dev/mapper/hyper-rw-vm1", "/srv/hyper/vmlinux/k")

    assert opts.vm_id == "vm1"
    assert opts.uid == 900_000 and opts.gid == 900_000
    assert opts.type == :base and opts.arch == :x86_64
    assert opts.source.root_drive_path == "/dev/mapper/hyper-rw-vm1"
    assert opts.source.kernel_image_path == "/srv/hyper/vmlinux/k"
  end
end
