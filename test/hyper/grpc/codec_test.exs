defmodule Hyper.Grpc.CodecTest do
  use ExUnit.Case, async: true

  alias Hyper.Grpc.Codec
  alias Hyper.Grpc.V1.CreateVmRequest
  alias Hyper.Grpc.V1.CreateVmResponse
  alias Hyper.Grpc.V1.GetVmResponse
  alias Hyper.Grpc.V1.GetVmUsageResponse
  alias Hyper.Grpc.V1.ListVmsResponse
  alias Hyper.Grpc.V1.LoadImageRequest
  alias Hyper.Grpc.V1.LoadImageResponse
  alias Hyper.Grpc.V1.StopVmResponse
  alias Hyper.Vm.Spec

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

  test "an unset instance_type (UNSPECIFIED) is rejected as required, not defaulted" do
    assert {:error, :missing_instance_type} =
             Codec.from_grpc(%CreateVmRequest{
               img_id: "img",
               instance_type: :INSTANCE_TYPE_UNSPECIFIED,
               arch: :ARCHITECTURE_X86_64
             })

    assert %GRPC.RPCError{status: 3} = Codec.to_grpc({:error, :missing_instance_type})
  end

  test "an unset arch (UNSPECIFIED) is rejected as required, not defaulted" do
    assert {:error, :missing_arch} =
             Codec.from_grpc(%CreateVmRequest{
               img_id: "img",
               instance_type: :INSTANCE_TYPE_MICRO,
               arch: :ARCHITECTURE_UNSPECIFIED
             })

    assert %GRPC.RPCError{status: 3} = Codec.to_grpc({:error, :missing_arch})
  end

  test "a vms page maps to ListVmsResponse carrying the next_page_token" do
    assert %ListVmsResponse{vms: [%{vm_id: "a"}], next_page_token: "cursor"} =
             Codec.to_grpc({:vms, [{"a", :node@host}], "cursor"})
  end

  test "a malformed page_token maps to INVALID_ARGUMENT" do
    assert %GRPC.RPCError{status: 3} = Codec.to_grpc({:error, :bad_page_token})
  end

  # `from_grpc/1` -- the decode boundary. The contract: an inbound CreateVmRequest
  # maps to a domain Spec with the right field placement, or is refused with a
  # specific reason the server then classifies to a gRPC status.
  describe "from_grpc/1 CreateVmRequest" do
    test "a well-formed request decodes to a Spec preserving every field" do
      assert {:ok,
              %Spec{
                img_id: "img",
                type: :micro,
                arch: :aarch64,
                boot_args: "console=ttyS0"
              }} =
               Codec.from_grpc(%CreateVmRequest{
                 img_id: "img",
                 instance_type: :INSTANCE_TYPE_MICRO,
                 arch: :ARCHITECTURE_AARCH64,
                 boot_args: "console=ttyS0"
               })
    end

    test "a missing img_id (nil or empty) is refused" do
      assert {:error, :missing_img_id} =
               Codec.from_grpc(%CreateVmRequest{img_id: nil, instance_type: :INSTANCE_TYPE_MICRO})

      assert {:error, :missing_img_id} =
               Codec.from_grpc(%CreateVmRequest{img_id: "", instance_type: :INSTANCE_TYPE_MICRO})
    end
  end

  describe "from_grpc/1 LoadImageRequest" do
    test "a request with no label decodes to an empty opts list" do
      assert {:ok, {"alpine:3.19", []}} =
               Codec.from_grpc(%LoadImageRequest{image_ref: "alpine:3.19", label: nil})

      assert {:ok, {"alpine:3.19", []}} =
               Codec.from_grpc(%LoadImageRequest{image_ref: "alpine:3.19", label: ""})
    end

    test "a request carrying a label forwards it as a labelled opt" do
      assert {:ok, {"alpine:3.19", [label: "prod"]}} =
               Codec.from_grpc(%LoadImageRequest{image_ref: "alpine:3.19", label: "prod"})
    end

    test "a missing image_ref (nil or empty) is refused" do
      assert {:error, :missing_image_ref} = Codec.from_grpc(%LoadImageRequest{image_ref: nil})
      assert {:error, :missing_image_ref} = Codec.from_grpc(%LoadImageRequest{image_ref: ""})
    end
  end

  # `to_grpc/1` -- the encode boundary. The contract: each domain result maps to
  # the response message carrying exactly the fields a client reads.
  describe "to_grpc/1 response encoding" do
    test "a created result carries the vm_id and node string" do
      assert %CreateVmResponse{vm_id: "vabc", node: "hyper@host"} =
               Codec.to_grpc({:created, "vabc", :hyper@host})
    end

    test "a located result carries the vm_id and node string" do
      assert %GetVmResponse{vm_id: "vabc", node: "hyper@host"} =
               Codec.to_grpc({:located, "vabc", :hyper@host})
    end

    test "a loaded result carries the image id" do
      assert %LoadImageResponse{img_id: "img-1"} = Codec.to_grpc({:loaded, "img-1"})
    end
  end

  # `rpc_error/1` -- the status-classification contract. The server promises each
  # domain reason a specific gRPC status; a mutation that swaps two statuses would
  # silently change what clients see. Table-driven: one assertion shape, rows
  # differ only in the reason and expected status.
  describe "to_grpc {:error, _} status classification" do
    @status_cases [
      {:missing_img_id, GRPC.Status.invalid_argument()},
      {:missing_image_ref, GRPC.Status.invalid_argument()},
      {:invalid_ref, GRPC.Status.invalid_argument()},
      {:machine_unreachable, GRPC.Status.unavailable()},
      {:no_capacity, GRPC.Status.resource_exhausted()},
      {:exhausted, GRPC.Status.resource_exhausted()},
      # A control-only cluster cannot load an image anywhere. That is a
      # precondition the operator can fix, not the INTERNAL the fallback would
      # otherwise report.
      {:no_host, GRPC.Status.failed_precondition()}
    ]

    test "each domain reason maps to its promised gRPC status" do
      for {reason, status} <- @status_cases do
        assert %GRPC.RPCError{status: ^status} = Codec.to_grpc({:error, reason})
      end
    end

    test "a missing-tools error names the offending tools in the message" do
      status = GRPC.Status.failed_precondition()

      assert %GRPC.RPCError{
               status: ^status,
               message: "node is missing required image tools: umoci, skopeo"
             } = Codec.to_grpc({:error, {:missing_tools, ["umoci", "skopeo"]}})
    end

    test "an unrecognised reason never crashes and falls back to INTERNAL" do
      status = GRPC.Status.internal()

      assert %GRPC.RPCError{status: ^status, message: msg} =
               Codec.to_grpc({:error, :something_truly_novel})

      assert msg =~ "something_truly_novel"
    end
  end
end
