defmodule Hyper.Node.FireVMM.ChrootJail do
  @moduledoc """
  Places a VM's boot artifacts inside its jailer chroot and points the boot spec
  at them.

  firecracker runs chrooted, so the kernel (a regular file) is hardlinked/copied
  in and the writable rootfs (a block device) gets a matching device node
  `mknod`-ed in - both chowned to the jail uid/gid via the setuid helper. The
  resolved `BootSpec.Cold` carries HOST paths; `stage/4` stages them into the
  chroot and returns a copy whose kernel + rootfs paths are the in-jail
  (chroot-relative) equivalents the chrooted firecracker can open.
  """

  alias Hyper.Node.FireVMM.BootSpec.Cold

  # In-jail filenames + the rootfs drive id (matches BootSpec.resolve/2).
  @kernel_name "vmlinux"
  @root_name "rootfs"
  @root_drive_id "rootfs"

  # The helper places the kernel at <chroot_root>/@kernel_name and the rootfs
  # node at <chroot_root>/@root_name; those names are the contract it rewrites
  # the spec against below.
  @spec jailify(Cold.t()) :: Cold.t()
  def jailify(%Cold{} = cold), do: jailify(cold, in_jail(@kernel_name), in_jail(@root_name))

  # Rewrite the boot source's kernel path and the rootfs drive's path to the
  # given in-jail paths; other drives are left untouched.
  @spec jailify(Cold.t(), String.t(), String.t()) :: Cold.t()
  defp jailify(%Cold{} = cold, jail_kernel, jail_root) do
    %Cold{
      cold
      | boot_source: %{cold.boot_source | kernel_image_path: jail_kernel},
        drives: Enum.map(cold.drives, &rewrite_drive(&1, jail_root))
    }
  end

  defp rewrite_drive(%{drive_id: @root_drive_id} = drive, jail_root) do
    %{drive | path_on_host: jail_root}
  end

  defp rewrite_drive(drive, _jail_root), do: drive

  defp in_jail(name), do: "/" <> name
end
