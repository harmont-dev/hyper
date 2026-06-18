defmodule Hyper.Node.ImageStoreTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.ImageStore

  test "exposes the provisioning facade" do
    assert function_exported?(ImageStore, :start_link, 1)
    assert function_exported?(ImageStore, :provision, 3)
    assert function_exported?(ImageStore, :release, 1)
    assert function_exported?(ImageStore, :snapshot, 2)
    assert function_exported?(ImageStore, :stats, 0)
  end

  test "init wires exactly four children" do
    assert {:ok, {_flags, children}} = ImageStore.init([])
    assert length(children) == 4
  end

  test "facade functions are not implemented yet" do
    src = {:snapshot, "/tmp/snap"}

    assert_raise RuntimeError, "not implemented", fn -> ImageStore.provision(self(), src, "/jail") end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.release(self()) end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.snapshot(self(), self()) end
    assert_raise RuntimeError, "not implemented", fn -> ImageStore.stats() end
  end
end
