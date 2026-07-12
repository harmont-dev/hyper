defmodule Hyper.Grpc.CodecForkTest do
  use ExUnit.Case, async: true

  alias Hyper.Grpc.Codec
  alias Hyper.Grpc.V1.ForkVmResponse

  test "a forked result maps to a ForkVmResponse with the child id and node string" do
    assert %ForkVmResponse{vm_id: "child-abc", node: "hyper@host"} =
             Codec.to_grpc({:forked, "child-abc", :hyper@host})
  end

  test "node_unreachable maps to an UNAVAILABLE gRPC error" do
    err = Codec.to_grpc({:error, :node_unreachable})
    assert %GRPC.RPCError{status: status} = err
    assert status == GRPC.Status.unavailable()
  end
end
