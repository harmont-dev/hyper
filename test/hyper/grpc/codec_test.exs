defmodule Hyper.Grpc.CodecTest do
  use ExUnit.Case, async: true

  alias Hyper.Grpc.Codec
  alias Hyper.Grpc.V0.{LoadImageRequest, LoadImageResponse}

  describe "from_grpc/1 (LoadImageRequest)" do
    test "rejects a blank image_ref" do
      assert Codec.from_grpc(%LoadImageRequest{image_ref: ""}) == {:error, :missing_image_ref}
      assert Codec.from_grpc(%LoadImageRequest{image_ref: nil}) == {:error, :missing_image_ref}
    end

    test "passes the ref through with no opts when label is unset" do
      assert Codec.from_grpc(%LoadImageRequest{image_ref: "alpine:3.19"}) ==
               {:ok, {"alpine:3.19", []}}

      assert Codec.from_grpc(%LoadImageRequest{image_ref: "alpine:3.19", label: ""}) ==
               {:ok, {"alpine:3.19", []}}
    end

    test "carries label as an opt when set" do
      assert Codec.from_grpc(%LoadImageRequest{image_ref: "alpine:3.19", label: "base"}) ==
               {:ok, {"alpine:3.19", [label: "base"]}}
    end
  end

  describe "to_grpc/1 (loaded)" do
    test "wraps the img_id in a LoadImageResponse" do
      assert Codec.to_grpc({:loaded, "oci-abc"}) == %LoadImageResponse{img_id: "oci-abc"}
    end
  end

  describe "to_grpc/1 (LoadImage error mapping)" do
    test "missing/invalid ref -> INVALID_ARGUMENT" do
      assert %GRPC.RPCError{status: status} = Codec.to_grpc({:error, :missing_image_ref})
      assert status == GRPC.Status.invalid_argument()
      assert Codec.to_grpc({:error, :invalid_ref}).status == GRPC.Status.invalid_argument()
    end

    test "missing tools -> FAILED_PRECONDITION" do
      err = Codec.to_grpc({:error, {:missing_tools, ["skopeo", "umoci"]}})
      assert err.status == GRPC.Status.failed_precondition()
    end

    test "tool/build/db failures -> INTERNAL" do
      assert Codec.to_grpc({:error, {:skopeo_failed, 1, "boom"}}).status == GRPC.Status.internal()

      assert Codec.to_grpc({:error, {:record_failed, :blob, :db}}).status ==
               GRPC.Status.internal()
    end
  end
end
