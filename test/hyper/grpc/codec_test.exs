defmodule Hyper.Grpc.CodecTest do
  use ExUnit.Case, async: true

  alias Hyper.Grpc.Codec
  alias Hyper.Grpc.V0.GetVmUsageResponse

  test "usage encodes as microseconds on the wire" do
    assert %GetVmUsageResponse{vm_id: "v1", cpu_usec: 1_500_000} =
             Codec.to_grpc({:usage, "v1", Unit.Time.ms(1_500)})
  end

  test "not_found maps to the NOT_FOUND status" do
    assert %GRPC.RPCError{status: 5} = Codec.to_grpc({:error, :not_found})
  end
end
