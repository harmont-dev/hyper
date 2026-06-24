defmodule Hyper.Grpc.Server do
  @moduledoc """
  gRPC handler for `hyper.grpc.v0.Hyper`. A thin translation layer: each RPC
  maps its request to a domain value via `Hyper.Grpc.Codec.from_grpc/1`, calls
  the existing `Hyper` BEAM API, and maps the result back with
  `Hyper.Grpc.Codec.to_grpc/1` (raising the `GRPC.RPCError` it returns on error).
  """

  use GRPC.Server, service: Hyper.Grpc.V0.Hyper.Service

  alias Google.Protobuf.Empty
  alias Hyper.Grpc.Codec

  alias Hyper.Grpc.V0.{
    CreateVmRequest,
    CreateVmResponse,
    GetVmRequest,
    GetVmResponse,
    ListVmsResponse,
    LoadImageRequest,
    LoadImageResponse,
    StopVmRequest
  }

  @spec load_image(LoadImageRequest.t(), GRPC.Server.Stream.t()) :: LoadImageResponse.t()
  def load_image(%LoadImageRequest{} = req, _stream) do
    with {:ok, {ref, opts}} <- Codec.from_grpc(req),
         {:ok, img_id} <- Hyper.Img.OciLoader.load(ref, opts) do
      Codec.to_grpc({:loaded, img_id})
    else
      {:error, reason} -> raise Codec.to_grpc({:error, reason})
    end
  end

  @spec create_vm(CreateVmRequest.t(), GRPC.Server.Stream.t()) :: CreateVmResponse.t()
  def create_vm(%CreateVmRequest{} = req, _stream) do
    with {:ok, spec} <- Codec.from_grpc(req),
         {:ok, pid} <- Hyper.create_vm(spec),
         vm_id when is_binary(vm_id) <- Hyper.id(pid) do
      Codec.to_grpc({:created, vm_id, node(pid)})
    else
      # Hyper.id/1 could not resolve the id: the VM was placed but its host
      # became unreachable. Surface that rather than returning an empty vm_id.
      nil -> raise Codec.to_grpc({:error, :machine_unreachable})
      {:error, reason} -> raise Codec.to_grpc({:error, reason})
    end
  end

  @spec stop_vm(StopVmRequest.t(), GRPC.Server.Stream.t()) :: Empty.t()
  def stop_vm(%StopVmRequest{vm_id: vm_id}, _stream) do
    Hyper.Node.FireVMM.State.stop(vm_id)
    Codec.to_grpc(:stopped)
  catch
    :exit, reason -> raise Codec.to_grpc({:exit, reason})
  end

  @spec get_vm(GetVmRequest.t(), GRPC.Server.Stream.t()) :: GetVmResponse.t()
  def get_vm(%GetVmRequest{vm_id: vm_id}, _stream) do
    case Hyper.whereis(vm_id) do
      nil -> raise Codec.to_grpc({:error, :not_found})
      node -> Codec.to_grpc({:located, vm_id, node})
    end
  end

  @spec list_vms(Empty.t(), GRPC.Server.Stream.t()) :: ListVmsResponse.t()
  def list_vms(%Empty{}, _stream) do
    Codec.to_grpc({:vms, Hyper.Cluster.Routing.all()})
  end
end
