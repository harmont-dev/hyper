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
  @spec stage(Hyper.Vm.id(), non_neg_integer(), non_neg_integer(), Cold.t()) ::
          {:ok, Cold.t()} | {:error, term()}
  @decorate with_span("Hyper.Node.FireVMM.ChrootJail.stage", include: [:vm_id])
  def stage(vm_id, uid, gid, %Cold{} = cold) do
    with {:ok, jail_kernel} <- stage_kernel(vm_id, uid, gid, cold.boot_source.kernel_image_path),
         {:ok, jail_root} <- stage_root_drive(vm_id, uid, gid, root_drive_host_path(cold)) do
      {:ok, jailify(cold, jail_kernel, jail_root)}
    end
  end

  # Hardlink/copy the kernel file into the chroot; return its in-jail path.
  @spec stage_kernel(Hyper.Vm.id(), non_neg_integer(), non_neg_integer(), Path.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp stage_kernel(vm_id, uid, gid, host_kernel) do
    dest = Path.join(Jailer.chroot_root(vm_id), @kernel_name)

    case SuidHelper.Jail.stage(host_kernel, dest, uid, gid) do
      :ok -> {:ok, in_jail(@kernel_name)}
      {:error, _} = err -> err
    end
  end

  # Create the rootfs device node (mirroring `host_dev`) in the chroot; return its
  # in-jail path.
  @spec stage_root_drive(Hyper.Vm.id(), non_neg_integer(), non_neg_integer(), Path.t()) ::
          {:ok, String.t()} | {:error, term()}
  defp stage_root_drive(vm_id, uid, gid, host_dev) do
    dest = Path.join(Jailer.chroot_root(vm_id), @root_name)

    case SuidHelper.Jail.mknod(dest, host_dev, uid, gid) do
      :ok -> {:ok, in_jail(@root_name)}
      {:error, _} = err -> err
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
