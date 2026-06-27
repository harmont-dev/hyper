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

  use OpenTelemetryDecorator

  alias Hyper.Node.FireVMM.BootSpec.Cold
  alias Hyper.Node.FireVMM.Jailer
  alias Hyper.SuidHelper

  # In-jail filenames + the rootfs drive id (matches BootSpec.resolve/2).
  @kernel_name "vmlinux"
  @root_name "rootfs"
  @root_drive_id "rootfs"

  @doc """
  Stage `cold`'s host kernel + rootfs device into `vm_id`'s chroot (owned
  `uid:gid`), and return `cold` with its kernel + rootfs paths rewritten to their
  in-jail equivalents. Fails the boot if either artifact cannot be staged.
  """
  @spec stage(Hyper.Vm.Id.t(), non_neg_integer(), non_neg_integer(), Cold.t()) ::
          {:ok, Cold.t()} | {:error, term()}
  @decorate with_span("Hyper.Node.FireVMM.ChrootJail.stage", include: [:vm_id])
  def stage(vm_id, uid, gid, %Cold{} = cold) do
    chroot_root = Jailer.chroot_root(vm_id)
    kernel = cold.boot_source.kernel_image_path
    device = root_drive_host_path(cold)

    # The helper places the kernel at <chroot_root>/@kernel_name and the rootfs
    # node at <chroot_root>/@root_name; those names are the contract it rewrites
    # the spec against below.
    with :ok <- SuidHelper.ChrootJail.prepare(chroot_root, kernel, device, uid, gid) do
      {:ok, jailify(cold, in_jail(@kernel_name), in_jail(@root_name))}
    end
  end

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

  # The host path of the rootfs drive (BootSpec.resolve always produces one).
  @spec root_drive_host_path(Cold.t()) :: Path.t() | nil
  defp root_drive_host_path(%Cold{drives: drives}) do
    Enum.find_value(drives, fn
      %{drive_id: @root_drive_id, path_on_host: path} -> path
      _ -> nil
    end)
  end

  defp in_jail(name), do: "/" <> name
end
