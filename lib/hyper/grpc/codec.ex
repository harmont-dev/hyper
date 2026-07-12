defmodule Hyper.Grpc.Codec do
  @moduledoc """
  Translation between the gRPC wire types (`Hyper.Grpc.V1.*`) and Hyper's domain
  types. Two entry points, each dispatching by pattern match on the value's type:

    * `from_grpc/1` -- an inbound request message -> a domain value.
    * `to_grpc/1`   -- a domain result (or error) -> an outbound response message,
      or a `GRPC.RPCError` for the server to raise.
  """

  alias Hyper.Grpc.V1.{
    CreateVmRequest,
    CreateVmResponse,
    ForkVmResponse,
    GetVmResponse,
    GetVmUsageResponse,
    ListVmsResponse,
    LoadImageRequest,
    LoadImageResponse,
    StopVmResponse,
    Vm
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

  @doc "Convert an inbound request message to a domain value."
  @spec from_grpc(CreateVmRequest.t()) :: {:ok, Spec.t()} | {:error, term()}
  def from_grpc(%CreateVmRequest{img_id: img_id}) when img_id in [nil, ""],
    do: {:error, :missing_img_id}

  def from_grpc(%CreateVmRequest{} = req) do
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

  @spec from_grpc(LoadImageRequest.t()) ::
          {:ok, {String.t(), keyword()}} | {:error, :missing_image_ref}
  def from_grpc(%LoadImageRequest{image_ref: ref}) when ref in [nil, ""],
    do: {:error, :missing_image_ref}

  def from_grpc(%LoadImageRequest{image_ref: ref, label: label}) do
    opts = if label in [nil, ""], do: [], else: [label: label]
    {:ok, {ref, opts}}
  end

  @doc "Convert a domain result to an outbound response message, or an error to `GRPC.RPCError`."
  @spec to_grpc({:created, Hyper.Vm.Id.t(), node()}) :: CreateVmResponse.t()
  def to_grpc({:created, vm_id, node}) when is_binary(vm_id),
    do: %CreateVmResponse{vm_id: vm_id, node: to_string(node)}

  @spec to_grpc({:forked, Hyper.Vm.Id.t(), node()}) :: ForkVmResponse.t()
  def to_grpc({:forked, vm_id, node}) when is_binary(vm_id),
    do: %ForkVmResponse{vm_id: vm_id, node: to_string(node)}

  @spec to_grpc({:located, Hyper.Vm.Id.t(), node()}) :: GetVmResponse.t()
  def to_grpc({:located, vm_id, node}),
    do: %GetVmResponse{vm_id: vm_id, node: to_string(node)}

  @spec to_grpc({:usage, Hyper.Vm.Id.t(), Unit.Time.t()}) :: GetVmUsageResponse.t()
  def to_grpc({:usage, vm_id, cpu_time}),
    do: %GetVmUsageResponse{vm_id: vm_id, cpu_usec: Unit.Time.as_us(cpu_time)}

  @spec to_grpc({:vms, [Hyper.Grpc.Page.entry()], String.t()}) :: ListVmsResponse.t()
  def to_grpc({:vms, vms, next_page_token}),
    do: %ListVmsResponse{vms: Enum.map(vms, &vm/1), next_page_token: next_page_token}

  @spec to_grpc({:loaded, Hyper.Img.id()}) :: LoadImageResponse.t()
  def to_grpc({:loaded, img_id}) when is_binary(img_id),
    do: %LoadImageResponse{img_id: img_id}

  @spec to_grpc(:stopped) :: StopVmResponse.t()
  def to_grpc(:stopped), do: %StopVmResponse{}

  @spec to_grpc({:error, term()}) :: GRPC.RPCError.t()
  def to_grpc({:error, reason}), do: rpc_error(reason)

  @spec vm({Hyper.Vm.Id.t(), node()}) :: Vm.t()
  defp vm({vm_id, node}), do: %Vm{vm_id: vm_id, node: to_string(node)}

  @spec instance_type(term()) ::
          {:ok, Hyper.Vm.Instance.t()} | {:error, :missing_instance_type | :bad_instance_type}
  defp instance_type(:INSTANCE_TYPE_UNSPECIFIED), do: {:error, :missing_instance_type}

  defp instance_type(enum) when is_map_key(@instance_types, enum),
    do: {:ok, @instance_types[enum]}

  defp instance_type(_unrecognised), do: {:error, :bad_instance_type}

  @spec arch(term()) :: {:ok, Hyper.Vm.Instance.arch()} | {:error, :missing_arch | :bad_arch}
  defp arch(:ARCHITECTURE_UNSPECIFIED), do: {:error, :missing_arch}

  defp arch(enum) when is_map_key(@arches, enum), do: {:ok, @arches[enum]}

  defp arch(_unrecognised), do: {:error, :bad_arch}

  @spec rpc_error(term()) :: GRPC.RPCError.t()
  defp rpc_error(:missing_img_id),
    do: GRPC.RPCError.exception(:invalid_argument, "img_id is required")

  defp rpc_error(:missing_instance_type),
    do: GRPC.RPCError.exception(:invalid_argument, "instance_type is required")

  defp rpc_error(:missing_arch),
    do: GRPC.RPCError.exception(:invalid_argument, "arch is required")

  defp rpc_error(:bad_page_token),
    do: GRPC.RPCError.exception(:invalid_argument, "page_token is malformed")

  defp rpc_error(:bad_instance_type),
    do: GRPC.RPCError.exception(:invalid_argument, "instance_type holds an unrecognised value")

  defp rpc_error(:bad_arch),
    do: GRPC.RPCError.exception(:invalid_argument, "arch holds an unrecognised value")

  defp rpc_error(:not_found),
    do: GRPC.RPCError.exception(:not_found, "no such VM")

  defp rpc_error(:machine_unreachable),
    do: GRPC.RPCError.exception(:unavailable, "VM's host node is unreachable")

  defp rpc_error(:node_unreachable),
    do: GRPC.RPCError.exception(:unavailable, "VM's host node is unreachable")

  defp rpc_error(reason) when reason in [:no_capacity, :exhausted],
    do: GRPC.RPCError.exception(:resource_exhausted, "no capacity")

  defp rpc_error(:missing_image_ref),
    do: GRPC.RPCError.exception(:invalid_argument, "image_ref is required")

  defp rpc_error(:invalid_ref),
    do: GRPC.RPCError.exception(:invalid_argument, "image_ref is malformed")

  defp rpc_error({:missing_tools, tools}),
    do:
      GRPC.RPCError.exception(
        :failed_precondition,
        "node is missing required image tools: #{Enum.join(tools, ", ")}"
      )

  defp rpc_error(reason),
    do: GRPC.RPCError.exception(:internal, "internal error: #{inspect(reason)}")
end
