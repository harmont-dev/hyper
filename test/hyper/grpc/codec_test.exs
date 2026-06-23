defmodule Hyper.Grpc.CodecTest do
  use ExUnit.Case, async: true

  alias Hyper.Grpc.Codec
  alias Hyper.Grpc.V1.CreateMachineRequest
  alias Hyper.Vm.Spec

  describe "to_spec/1" do
    test "maps a fully-specified request" do
      req = %CreateMachineRequest{
        img_id: "img-1",
        instance_type: :INSTANCE_TYPE_DECI,
        arch: :ARCHITECTURE_AARCH64,
        boot_args: "console=ttyS0"
      }

      assert {:ok,
              %Spec{img_id: "img-1", type: :deci, arch: :aarch64, boot_args: "console=ttyS0"}} =
               Codec.to_spec(req)
    end

    test "UNSPECIFIED instance type defaults to :base, arch to nil, empty boot_args to nil" do
      req = %CreateMachineRequest{
        img_id: "img-2",
        instance_type: :INSTANCE_TYPE_UNSPECIFIED,
        arch: :ARCHITECTURE_UNSPECIFIED,
        boot_args: ""
      }

      assert {:ok, %Spec{img_id: "img-2", type: :base, arch: nil, boot_args: nil}} =
               Codec.to_spec(req)
    end

    test "blank img_id is an invalid argument" do
      assert {:error, :missing_img_id} = Codec.to_spec(%CreateMachineRequest{img_id: ""})
    end
  end

  describe "rpc_error/1" do
    test "no_capacity maps to RESOURCE_EXHAUSTED" do
      assert %GRPC.RPCError{status: 8} = Codec.rpc_error(:no_capacity)
    end

    test "not_found maps to NOT_FOUND" do
      assert %GRPC.RPCError{status: 5} = Codec.rpc_error(:not_found)
    end

    test "missing_img_id maps to INVALID_ARGUMENT" do
      assert %GRPC.RPCError{status: 3} = Codec.rpc_error(:missing_img_id)
    end

    test "an unknown reason maps to INTERNAL" do
      assert %GRPC.RPCError{status: 13} = Codec.rpc_error({:boot_failed, :whatever})
    end

    test "machine_unreachable maps to UNAVAILABLE" do
      assert %GRPC.RPCError{status: 14} = Codec.rpc_error(:machine_unreachable)
    end
  end

  describe "stop_exit_error/1" do
    test ":noproc (unknown vm_id) maps to NOT_FOUND" do
      assert %GRPC.RPCError{status: 5} = Codec.stop_exit_error(:noproc)

      assert %GRPC.RPCError{status: 5} =
               Codec.stop_exit_error({:noproc, {:gen_statem, :call, []}})
    end

    test ":nodedown (downed host) maps to UNAVAILABLE" do
      assert %GRPC.RPCError{status: 14} = Codec.stop_exit_error(:nodedown)
      assert %GRPC.RPCError{status: 14} = Codec.stop_exit_error({:nodedown, :a@host})
    end

    test "any other exit reason maps to INTERNAL (a real crash is not masked as NOT_FOUND)" do
      assert %GRPC.RPCError{status: 13} = Codec.stop_exit_error(:killed)
      assert %GRPC.RPCError{status: 13} = Codec.stop_exit_error({:bad_return, :boom})
    end
  end
end
