defmodule Hyper.NodeTest do
  use ExUnit.Case, async: false

  # The :hyper application is already started, so Hyper.Node and its children
  # are running. Observe them rather than starting a second copy.

  test "ImageStore runs under the node tree" do
    assert is_pid(Process.whereis(Hyper.Node.ImageStore))
    assert Process.alive?(Process.whereis(Hyper.Node.ImageStore))
  end

  test "ImageStore children are running" do
    for name <- [
          Hyper.Node.ImageStore.BlobRegistry,
          Hyper.Node.ImageStore.TaskSupervisor,
          Hyper.Node.ImageStore.BlobSupervisor,
          Hyper.Node.ImageStore.Janitor
        ] do
      assert is_pid(Process.whereis(name)), "expected #{inspect(name)} to be running"
    end
  end

  test "VMSupervisor still runs alongside it" do
    assert is_pid(Process.whereis(Hyper.Node.VMSupervisor))
  end
end
