defmodule Hyper.SuidHelper.Vm do
  @moduledoc false

  use OpenTelemetryDecorator

  alias Hyper.SuidHelper

  @type err :: SuidHelper.err()

  @spec teardown(Hyper.Vm.Id.t(), non_neg_integer() | nil) :: :ok | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.teardown", include: [:vm_id, :uid])
  def teardown(vm_id, uid) do
    run(%{op: "vm_teardown", id: vm_id, uid: uid})
  end

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
  @spec claim_api_socket(Hyper.Vm.Id.t()) :: :ok | {:error, :socket_pending} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.claim_api_socket", include: [:vm_id])
  def claim_api_socket(vm_id) do
    case SuidHelper.exec(%{op: "vm_claim_api_socket", id: vm_id}) do
      {:ok, %{"result" => "claimed"}} -> :ok
      {:ok, %{"result" => "pending"}} -> {:error, :socket_pending}
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
  @spec claim_vsock_socket(Hyper.Vm.Id.t()) :: :ok | {:error, :socket_pending} | {:error, err()}
  @decorate with_span("Hyper.SuidHelper.Vm.claim_vsock_socket", include: [:vm_id])
  def claim_vsock_socket(vm_id) do
    case SuidHelper.exec(%{op: "vm_claim_vsock_socket", id: vm_id}) do
      {:ok, %{"result" => "claimed"}} -> :ok
      {:ok, %{"result" => "pending"}} -> {:error, :socket_pending}
      {:error, _} = err -> err
    end
  end

  @spec run(map()) :: :ok | {:error, err()}
  defp run(request) do
    case SuidHelper.exec(request) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end
end
