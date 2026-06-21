defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Firecracker.Api.{BootSource, Drive, MachineConfiguration}
  alias Hyper.Node.FireVMM.BootSpec

  describe "resolve/2" do
    test "maps instance type to machine config (vcpus ceil-ed, mem in MiB)" do
      src = %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}
      assert %BootSpec.Cold{machine_config: mc} = BootSpec.resolve(src, :micro)
      # :micro is 0.25 vCPU, 128 MiB -> vcpu_count must be a positive integer.
      assert %MachineConfiguration{vcpu_count: 1, mem_size_mib: 128} = mc
    end

    test "builds boot source with default cmdline and a root drive" do
      src = %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}
      assert %BootSpec.Cold{boot_source: bs, drives: [drive]} = BootSpec.resolve(src, :centi)
      assert %BootSource{kernel_image_path: "/vmlinux", boot_args: args} = bs
      assert args =~ "console=ttyS0"

      assert %Drive{
               drive_id: "rootfs",
               is_root_device: true,
               is_read_only: false,
               path_on_host: "/rootfs.ext4"
             } = drive
    end

    test "honours explicit boot_args and read_only" do
      src = %{
        kernel_image_path: "/vmlinux",
        root_drive_path: "/ro.ext4",
        boot_args: "quiet",
        read_only: true
      }

      assert %BootSpec.Cold{boot_source: %BootSource{boot_args: "quiet"}, drives: [drive]} =
               BootSpec.resolve(src, :centi)

      assert %Drive{is_read_only: true} = drive
    end
  end
end
