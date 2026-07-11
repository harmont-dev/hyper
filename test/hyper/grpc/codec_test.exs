defmodule Hyper.Grpc.CodecTest do
  use ExUnit.Case, async: true

  alias Hyper.Grpc.Codec
  alias Hyper.Grpc.V0.CreateVmRequest
  alias Hyper.Grpc.V0.GetVmUsageResponse
  alias Hyper.Grpc.V0.StopVmResponse

  test "usage encodes as microseconds on the wire" do
    assert %GetVmUsageResponse{vm_id: "v1", cpu_usec: 1_500_000} =
             Codec.to_grpc({:usage, "v1", Unit.Time.ms(1_500)})
  end

  test "not_found maps to the NOT_FOUND status" do
    assert %GRPC.RPCError{status: 5} = Codec.to_grpc({:error, :not_found})
  end

  # proto3 decodes an unrecognised enum value to its bare integer; the proto
  # contract promises INVALID_ARGUMENT for it, never an INTERNAL crash.
  test "an unrecognised instance_type integer is refused, not crashed on" do
    assert {:error, :bad_instance_type} =
             Codec.from_grpc(%CreateVmRequest{
               img_id: "img",
               instance_type: 999,
               arch: :ARCHITECTURE_X86_64
             })

    assert %GRPC.RPCError{status: 3} = Codec.to_grpc({:error, :bad_instance_type})
  end

  test "an unrecognised arch integer is refused, not crashed on" do
    assert {:error, :bad_arch} =
             Codec.from_grpc(%CreateVmRequest{
               img_id: "img",
               instance_type: :INSTANCE_TYPE_MICRO,
               arch: 999
             })

    assert %GRPC.RPCError{status: 3} = Codec.to_grpc({:error, :bad_arch})
  end

  test "a stopped result maps to a StopVmResponse, not google.protobuf.Empty" do
    assert %StopVmResponse{} = Codec.to_grpc(:stopped)
  end
end
