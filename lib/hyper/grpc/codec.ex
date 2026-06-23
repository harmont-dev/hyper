defmodule Hyper.Grpc.Codec do
  @moduledoc """
  Pure mapping between the gRPC wire types (`Hyper.Grpc.V1.*`) and Hyper's domain
  types, plus domain-error → gRPC-status translation. Kept free of side effects
  so the server handler (`Hyper.Grpc.Server`) is a thin dispatch layer and this
  logic is unit-testable on its own.
  """

  alias Hyper.Grpc.V1.CreateMachineRequest
  alias Hyper.Vm.Spec

  @instance_types %{
    INSTANCE_TYPE_UNSPECIFIED: :base,
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
    ARCHITECTURE_UNSPECIFIED: nil,
    ARCHITECTURE_X86_64: :x86_64,
    ARCHITECTURE_AARCH64: :aarch64
  }

  @doc "Build a `Hyper.Vm.Spec` from a `CreateMachineRequest`."
  @spec to_spec(CreateMachineRequest.t()) :: {:ok, Spec.t()} | {:error, term()}
  def to_spec(%CreateMachineRequest{img_id: img_id})
      when img_id in [nil, ""],
      do: {:error, :missing_img_id}

  def to_spec(%CreateMachineRequest{} = req) do
    with {:ok, type} <- instance_type(req.instance_type),
         {:ok, arch} <- arch(req.arch) do
      {:ok,
       %Spec{
         img_id: req.img_id,
         type: type,
         arch: arch,
         boot_args: blank_to_nil(req.boot_args)
       }}
    end
  end

  @doc "Translate a domain error reason into a gRPC status error."
  @spec rpc_error(term()) :: GRPC.RPCError.t()
  def rpc_error(:missing_img_id),
    do: GRPC.RPCError.exception(:invalid_argument, "img_id is required")

  def rpc_error({:invalid_instance_type, _} = _r),
    do: GRPC.RPCError.exception(:invalid_argument, "unknown instance_type")

  def rpc_error({:invalid_arch, _} = _r),
    do: GRPC.RPCError.exception(:invalid_argument, "unknown arch")

  def rpc_error(:not_found),
    do: GRPC.RPCError.exception(:not_found, "no such machine")

  def rpc_error(reason) when reason in [:no_capacity, :exhausted],
    do: GRPC.RPCError.exception(:resource_exhausted, "no capacity")

  def rpc_error(:machine_unreachable),
    do: GRPC.RPCError.exception(:unavailable, "machine's host node is unreachable")

  def rpc_error(reason),
    do: GRPC.RPCError.exception(:internal, "internal error: #{inspect(reason)}")

  @doc """
  Map a `:gen_statem` call exit reason (raised by `Hyper.Node.FireVMM.State.stop/1`
  when the call cannot complete) to a gRPC status. An unregistered vm_id exits
  `:noproc` → NOT_FOUND; a downed host exits `:nodedown` → UNAVAILABLE; anything
  else is a genuine controller failure → INTERNAL (so a real crash is never
  silently reported as a clean NOT_FOUND).
  """
  @spec stop_exit_error(term()) :: GRPC.RPCError.t()
  def stop_exit_error(:noproc), do: rpc_error(:not_found)
  def stop_exit_error({:noproc, _}), do: rpc_error(:not_found)
  def stop_exit_error(:nodedown), do: rpc_error(:machine_unreachable)
  def stop_exit_error({:nodedown, _}), do: rpc_error(:machine_unreachable)
  def stop_exit_error(reason), do: rpc_error({:stop_failed, reason})

  @spec instance_type(atom()) :: {:ok, Hyper.Vm.Instance.t()} | {:error, term()}
  defp instance_type(enum) when is_map_key(@instance_types, enum),
    do: {:ok, Map.fetch!(@instance_types, enum)}

  defp instance_type(enum), do: {:error, {:invalid_instance_type, enum}}

  @spec arch(atom()) :: {:ok, Hyper.Vm.Instance.arch() | nil} | {:error, term()}
  defp arch(enum) when is_map_key(@arches, enum), do: {:ok, Map.fetch!(@arches, enum)}
  defp arch(enum), do: {:error, {:invalid_arch, enum}}

  @spec blank_to_nil(String.t() | nil) :: String.t() | nil
  defp blank_to_nil(s) when s in [nil, ""], do: nil
  defp blank_to_nil(s), do: s
end
