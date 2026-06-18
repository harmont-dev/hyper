defmodule Hyper.Node.ImageStore.BlobTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.ImageStore.Blob

  test "exposes the per-blob lifecycle API" do
    Code.ensure_loaded!(Blob)
    assert function_exported?(Blob, :start_link, 1)
    assert function_exported?(Blob, :child_spec, 1)
    assert function_exported?(Blob, :acquire, 2)
    assert function_exported?(Blob, :release, 2)
    assert function_exported?(Blob, :try_evict, 1)
  end

  test "child_spec is keyed by hash and temporary" do
    spec = Blob.child_spec("sha256:abc")

    assert spec.id == {Blob, "sha256:abc"}
    assert spec.restart == :temporary
  end

  test "init carries the blob hash" do
    assert Blob.init("sha256:abc") == {:ok, %{hash: "sha256:abc"}}
  end

  test "lifecycle functions are not implemented yet" do
    assert_raise RuntimeError, "not implemented", fn -> Blob.acquire("sha256:abc", self()) end
    assert_raise RuntimeError, "not implemented", fn -> Blob.release("sha256:abc", self()) end
    assert_raise RuntimeError, "not implemented", fn -> Blob.try_evict("sha256:abc") end
  end
end
