defmodule Hyper.Node.FireVMM.Jail.Stage do
  @moduledoc """
  Stages a VM's boot artifacts into its jailer chroot. firecracker runs chrooted,
  so the kernel (a regular file) is hardlinked/copied in and the writable rootfs
  (a block device) gets a matching device node `mknod`-ed in - both chowned to the
  jail uid/gid so firecracker can open them. Returns the in-jail (leading-slash)
  paths to use in the boot config.
  """

  use OpenTelemetryDecorator

  alias Hyper.Node.FireVMM.Jailer
  alias Hyper.SuidHelper

  @kernel_name "vmlinux"
  @root_name "rootfs"

  @spec jail_kernel_name() :: String.t()
  def jail_kernel_name, do: @kernel_name

  @spec jail_root_name() :: String.t()
  def jail_root_name, do: @root_name

  @doc "In-jail absolute path for a staged file `name`."
  @spec jail_path(String.t()) :: String.t()
  def jail_path(name), do: "/" <> name

  @doc "Stage the kernel file; returns its in-jail path."
  @spec kernel(Hyper.Vm.id(), non_neg_integer(), non_neg_integer(), Path.t()) ::
          {:ok, String.t()} | {:error, term()}
  @decorate with_span("Hyper.Node.FireVMM.Jail.Stage.kernel", include: [:vm_id])
  def kernel(vm_id, uid, gid, host_kernel_path) do
    dest = Path.join(Jailer.chroot_root(vm_id), @kernel_name)

    case SuidHelper.Jail.stage(host_kernel_path, dest, uid, gid) do
      :ok -> {:ok, jail_path(@kernel_name)}
      {:error, _} = err -> err
    end
  end

  @doc "Create the rootfs device node mirroring `host_dev`; returns its in-jail path."
  @spec root_drive(Hyper.Vm.id(), non_neg_integer(), non_neg_integer(), Path.t()) ::
          {:ok, String.t()} | {:error, term()}
  @decorate with_span("Hyper.Node.FireVMM.Jail.Stage.root_drive", include: [:vm_id])
  def root_drive(vm_id, uid, gid, host_dev) do
    dest = Path.join(Jailer.chroot_root(vm_id), @root_name)

    case SuidHelper.Jail.mknod(dest, host_dev, uid, gid) do
      :ok -> {:ok, jail_path(@root_name)}
      {:error, _} = err -> err
    end
  end
end
