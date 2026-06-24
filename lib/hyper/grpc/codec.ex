defmodule Hyper.Grpc.Codec do
  @moduledoc """
  Translation between the gRPC wire types (`Hyper.Grpc.V0.*`) and Hyper's domain
  types. Two entry points, each dispatching by pattern match on the value's type:

    * `from_grpc/1` — an inbound request message → a domain value.
    * `to_grpc/1`   — a domain result (or error) → an outbound response message,
      or a `GRPC.RPCError` for the server to raise.
  """

  alias Hyper.Grpc.V0.{
    CreateMachineRequest,
    CreateMachineResponse,
    GetMachineResponse,
    ListMachinesResponse,
    Machine,
    StopMachineResponse
  }

  alias Hyper.Vm.Spec

  @instance_types %{
    INSTANCE_TYPE_MICRO: :micro,
    INSTANCE_TYPE_MILLI: :milli,
    INSTANCE_TYPE_CENTI: :centi,
    INSTANCE_TYPE_DECI: :deci,
    INSTANCE_TYPE_BASE: :base,
    INSTANCE_TYPE_DECA: :deca,
    INSTANCE_TYPE_HECTO: :hecto,
    INSTANCE_TYPE_KILO: :kilo,
    INSTANCE_TYPE_MEGA: :mega,
    INSTANCE_TYPE_GIGA: :giga,
    INSTANCE_TYPE_TERA: :tera
  }

  @arches %{
    ARCHITECTURE_X86_64: :x86_64,
    ARCHITECTURE_AARCH64: :aarch64
  }

  @typep instance_enum ::
           :INSTANCE_TYPE_MICRO
           | :INSTANCE_TYPE_MILLI
           | :INSTANCE_TYPE_CENTI
           | :INSTANCE_TYPE_DECI
           | :INSTANCE_TYPE_BASE
           | :INSTANCE_TYPE_DECA
           | :INSTANCE_TYPE_HECTO
           | :INSTANCE_TYPE_KILO
           | :INSTANCE_TYPE_MEGA
           | :INSTANCE_TYPE_GIGA
           | :INSTANCE_TYPE_TERA

  @typep arch_enum :: :ARCHITECTURE_X86_64 | :ARCHITECTURE_AARCH64

  @doc "Convert an inbound request message to a domain value."
  @spec from_grpc(CreateMachineRequest.t()) :: {:ok, Spec.t()} | {:error, term()}
  def from_grpc(%CreateMachineRequest{img_id: img_id}) when img_id in [nil, ""],
    do: {:error, :missing_img_id}

  def from_grpc(%CreateMachineRequest{} = req) do
    with {:ok, type} <- instance_type(req.instance_type),
         {:ok, arch} <- arch(req.arch) do
      {:ok,
       %Spec{
         img_id: req.img_id,
         type: type,
         arch: arch,
         boot_args: req.boot_args
       }}
    end
  end

  @doc "Convert a domain result to an outbound response message, or an error to `GRPC.RPCError`."
  @spec to_grpc({:created, Hyper.Vm.id(), node()}) :: CreateMachineResponse.t()
  def to_grpc({:created, vm_id, node}) when is_binary(vm_id),
    do: %CreateMachineResponse{vm_id: vm_id, node: to_string(node)}

  @spec to_grpc({:located, Hyper.Vm.id(), node()}) :: GetMachineResponse.t()
  def to_grpc({:located, vm_id, node}),
    do: %GetMachineResponse{vm_id: vm_id, node: to_string(node)}

  @spec to_grpc({:machines, [{Hyper.Vm.id(), node()}]}) :: ListMachinesResponse.t()
  def to_grpc({:machines, machines}),
    do: %ListMachinesResponse{machines: Enum.map(machines, &machine/1)}

  @spec to_grpc(:stopped) :: StopMachineResponse.t()
  def to_grpc(:stopped), do: %StopMachineResponse{}

  @spec to_grpc({:error, term()}) :: GRPC.RPCError.t()
  def to_grpc({:error, reason}), do: rpc_error(reason)

  # A :gen_statem call exit from State.stop/1: :noproc (unknown vm_id) → NOT_FOUND,
  # :nodedown (downed host) → UNAVAILABLE, anything else is a real controller
  # failure → INTERNAL, so a genuine crash is never masked as a clean NOT_FOUND.
  @spec to_grpc({:exit, term()}) :: GRPC.RPCError.t()
  def to_grpc({:exit, :noproc}), do: rpc_error(:not_found)
  def to_grpc({:exit, {:noproc, _}}), do: rpc_error(:not_found)
  def to_grpc({:exit, :nodedown}), do: rpc_error(:machine_unreachable)
  def to_grpc({:exit, {:nodedown, _}}), do: rpc_error(:machine_unreachable)
  def to_grpc({:exit, reason}), do: rpc_error({:stop_failed, reason})

  @spec machine({Hyper.Vm.id(), node()}) :: Machine.t()
  defp machine({vm_id, node}), do: %Machine{vm_id: vm_id, node: to_string(node)}

  @spec instance_type(nil) :: {:ok, :base}
  defp instance_type(nil), do: {:ok, :base}

  @spec instance_type(instance_enum()) :: {:ok, Hyper.Vm.Instance.t()}
  defp instance_type(enum) when is_map_key(@instance_types, enum),
    do: {:ok, @instance_types[enum]}

  @spec arch(nil) :: {:ok, nil}
  defp arch(nil), do: {:ok, nil}

  @spec arch(arch_enum()) :: {:ok, Hyper.Vm.Instance.arch()}
  defp arch(enum) when is_map_key(@arches, enum), do: {:ok, @arches[enum]}

  @spec rpc_error(term()) :: GRPC.RPCError.t()
  defp rpc_error(:missing_img_id),
    do: GRPC.RPCError.exception(:invalid_argument, "img_id is required")

  defp rpc_error(:not_found),
    do: GRPC.RPCError.exception(:not_found, "no such machine")

  defp rpc_error(:machine_unreachable),
    do: GRPC.RPCError.exception(:unavailable, "machine's host node is unreachable")

  defp rpc_error(reason) when reason in [:no_capacity, :exhausted],
    do: GRPC.RPCError.exception(:resource_exhausted, "no capacity")

  defp rpc_error(reason),
    do: GRPC.RPCError.exception(:internal, "internal error: #{inspect(reason)}")
end
