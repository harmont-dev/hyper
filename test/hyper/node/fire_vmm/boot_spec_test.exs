defmodule Hyper.Node.FireVMM.BootSpecTest do
  use ExUnit.Case, async: true

  alias Hyper.Firecracker.Api.{BootSource, Drive, MachineConfiguration, SnapshotLoadParams}
  alias Hyper.Node.FireVMM.BootSpec

  describe "resolve/2 cold" do
    test "maps instance type to machine config (vcpus ceil-ed, mem in MiB)" do
      src = {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}
      assert {:ok, %BootSpec.Cold{machine_config: mc}} = BootSpec.resolve(src, :micro)
      # :micro is 0.25 vCPU, 128 MiB -> vcpu_count must be a positive integer.
      assert %MachineConfiguration{vcpu_count: 1, mem_size_mib: 128} = mc
    end

    test "builds boot source with default cmdline and a root drive" do
      src = {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}
      assert {:ok, %BootSpec.Cold{boot_source: bs, drives: [drive]}} = BootSpec.resolve(src, :centi)
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
      src =
        {:cold,
         %{
           kernel_image_path: "/vmlinux",
           root_drive_path: "/ro.ext4",
           boot_args: "quiet",
           read_only: true
         }}

      assert {:ok, %BootSpec.Cold{boot_source: %BootSource{boot_args: "quiet"}, drives: [drive]}} =
               BootSpec.resolve(src, :centi)

      assert %Drive{is_read_only: true} = drive
    end
  end

  describe "resolve/2 restore" do
    test "maps a snapshot dir to load params that resume the guest" do
      assert {:ok, %BootSpec.Restore{params: params}} =
               BootSpec.resolve({:snapshot, "/snaps/v1"}, :centi)

      assert %SnapshotLoadParams{
               snapshot_path: "/snaps/v1/snapshot",
               mem_file_path: "/snaps/v1/mem",
               resume_vm: true
             } = params
    end
  end

  describe "resolve/2 unsupported" do
    test "fork-from-vm is not implemented yet" do
      assert {:error, {:unsupported_source, :vm}} = BootSpec.resolve({:vm, "vm-1"}, :centi)
    end
  end
end
