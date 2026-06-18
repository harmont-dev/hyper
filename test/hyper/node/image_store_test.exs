defmodule Hyper.Node.ImageStoreTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.ImageStore

  test "exposes the blob cache API" do
    Code.ensure_loaded!(ImageStore)
    assert function_exported?(ImageStore, :start_link, 1)
    assert function_exported?(ImageStore, :acquire, 2)
    assert function_exported?(ImageStore, :release, 2)
    assert function_exported?(ImageStore, :put, 1)
    assert function_exported?(ImageStore, :stats, 0)
  end

  test "init wires exactly four children" do
    assert {:ok, {_flags, children}} = ImageStore.init([])
    assert length(children) == 4
  end

  test "blob API is not implemented yet" do
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.acquire("sha256:x", self()) end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.release("sha256:x", self()) end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.put("/tmp/blob") end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.stats() end
  end
end
