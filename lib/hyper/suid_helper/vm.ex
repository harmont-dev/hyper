defmodule Hyper.SuidHelper.Vm do
  @moduledoc false

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @exit_retryable 75

  @doc """
  Prepare `chroot_root`'s boot artifacts: stage the `kernel` file in and `mknod`
  a node mirroring the rootfs `device`, both owned `uid:gid`. The helper places
  them at the fixed in-jail names (`/vmlinux`, `/rootfs`) and reads the device's
  major:minor itself.
  """
  @spec stage(Hyper.Vm.Id.t(), Path.t(), Path.t(), non_neg_integer(), non_neg_integer()) ::
          :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.stage", include: [:vm_id, :device])
  def stage(vm_id, kernel, device, uid, gid) do
    argv = [
      "vm",
      "stage",
      "--id",
      vm_id,
      "--kernel",
      kernel,
      "--device",
      device,
      "--uid",
      to_string(uid),
      "--gid",
      to_string(gid)
    ]

    run(argv)
  end

  @spec prepare(Hyper.Vm.Id.t(), non_neg_integer()) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.prepare", include: [:vm_id, :uid])
  def prepare(vm_id, uid) do
    run(["vm", "prepare", "--id", vm_id, "--uid", to_string(uid)])
  end

  @spec teardown(Hyper.Vm.Id.t(), non_neg_integer() | nil) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.teardown", include: [:vm_id, :uid])
  def teardown(vm_id, uid) do
    run(["vm", "teardown", "--id", vm_id] ++ uid_flag(uid))
  end

  @spec uid_flag(non_neg_integer() | nil) :: [String.t()]
  defp uid_flag(nil), do: []
  defp uid_flag(uid), do: ["--uid", to_string(uid)]

  @doc """
  Hand the firecracker API `socket` to the node user so the unprivileged
  controller can `connect()` to it. The jailer drops firecracker to a per-VM
  uid/gid and chroots it, so the socket it creates is owned by that per-VM id and
  the node (a different uid) gets `EACCES` on connect. The helper chowns just
  that one socket to its caller (the node user) and chmods it `0660`, leaving the
  rest of the per-VM isolation intact.

  Returns `{:error, :socket_pending}` while firecracker has not yet created the
  socket, so the caller can keep waiting.
  """
  @spec grant_api(Hyper.Vm.Id.t()) :: :ok | {:error, :socket_pending} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.grant_api", include: [:vm_id])
  def grant_api(vm_id) do
    case SuidHelper.exec(["vm", "grant-api", "--id", vm_id]) do
      {:ok, _} -> :ok
      {:error, {@exit_retryable, _}} -> {:error, :socket_pending}
      {:error, _} = err -> err
    end
  end

  @doc """
  Hand the firecracker vsock `socket` to the node user so the unprivileged
  controller can set up the guest AF_VSOCK connection. Firecracker creates the
  vsock Unix-domain socket inside the jail owned by the per-VM uid/gid; the node
  (a different uid) gets `EACCES`. The helper chowns just that one socket to its
  caller and chmods it `0660`, leaving the rest of the per-VM isolation intact.

  Returns `{:error, :socket_pending}` while firecracker has not yet created the
  vsock socket, so the caller can keep waiting.
  """
  @spec grant_vsock(Hyper.Vm.Id.t()) :: :ok | {:error, :socket_pending} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.grant_vsock", include: [:vm_id])
  def grant_vsock(vm_id) do
    case SuidHelper.exec(["vm", "grant-vsock", "--id", vm_id]) do
      {:ok, _} -> :ok
      {:error, {@exit_retryable, _}} -> {:error, :socket_pending}
      {:error, _} = err -> err
    end
  end

  @spec run([String.t()]) :: :ok | {:error, err()}
  defp run(argv) do
    case SuidHelper.exec(argv) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
