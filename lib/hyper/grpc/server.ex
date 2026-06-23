defmodule Hyper.Grpc.Server do
  @moduledoc """
  gRPC handler for `hyper.grpc.v1.Machines`. A thin translation layer: each RPC
  validates and maps its request via `Hyper.Grpc.Codec`, calls the existing
  `Hyper` BEAM API, and maps the result back to a wire response (or raises a
  `GRPC.RPCError` carrying the right status).

  The handler is stateless and identical on every node — placement and routing
  are already cluster-wide (`Hyper.Cluster.Scheduler`, `Hyper.Cluster.Routing`),
  so a call landing on any node is correct.
  """

  use GRPC.Server, service: Hyper.Grpc.V1.Machines.Service

  alias Hyper.Grpc.Codec

  alias Hyper.Grpc.V1.{
    CreateMachineRequest,
    CreateMachineResponse,
    GetMachineRequest,
    GetMachineResponse,
    ListMachinesResponse,
    Machine,
    StopMachineRequest,
    StopMachineResponse
  }

  @spec create_machine(CreateMachineRequest.t(), GRPC.Server.Stream.t()) ::
          CreateMachineResponse.t()
  def create_machine(%CreateMachineRequest{} = req, _stream) do
    with {:ok, spec} <- Codec.to_spec(req),
         {:ok, pid} <- Hyper.create_vm(spec) do
      %CreateMachineResponse{vm_id: Hyper.id(pid), node: to_string(node(pid))}
    else
      {:error, reason} -> raise Codec.rpc_error(reason)
    end
  end

  @spec stop_machine(StopMachineRequest.t(), GRPC.Server.Stream.t()) ::
          StopMachineResponse.t()
  def stop_machine(%StopMachineRequest{vm_id: vm_id}, _stream) do
    # State.stop/1 issues a gen_statem call to the VM's controller via the
    # cluster registry; an unknown vm_id has no registered name, so the call
    # exits with :noproc. Translate that into a clean NOT_FOUND.
    Hyper.Node.FireVMM.State.stop(vm_id)
    %StopMachineResponse{}
  catch
    :exit, _ -> raise Codec.rpc_error(:not_found)
  end

  @spec get_machine(GetMachineRequest.t(), GRPC.Server.Stream.t()) ::
          GetMachineResponse.t()
  def get_machine(%GetMachineRequest{vm_id: vm_id}, _stream) do
    case Hyper.whereis(vm_id) do
      nil -> raise Codec.rpc_error(:not_found)
      node -> %GetMachineResponse{vm_id: vm_id, node: to_string(node)}
    end
  end

  @spec list_machines(Hyper.Grpc.V1.ListMachinesRequest.t(), GRPC.Server.Stream.t()) ::
          ListMachinesResponse.t()
  def list_machines(_req, _stream) do
    machines =
      Enum.map(Hyper.Cluster.Routing.all(), fn {vm_id, node} ->
        %Machine{vm_id: vm_id, node: to_string(node)}
      end)

    %ListMachinesResponse{machines: machines}
  end
end
