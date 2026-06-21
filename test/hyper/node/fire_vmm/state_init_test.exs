defmodule Hyper.Node.FireVMM.StateInitTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.State

  test "init/1 carries id, source, type, and starts in :booting with a launch timeout" do
    source = %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}

    opts = %State.Opts{
      id: 42,
      source: source,
      type: :centi,
      socket_path: "/tmp/fake.socket",
      binary: "jailer",
      args: ["--id", "42"]
    }

    assert {:ok, :booting, data, [{:state_timeout, 0, :launch}]} = State.init(opts)
    assert data.id == 42
    assert data.source == source
    assert data.type == :centi
    assert data.socket_path == "/tmp/fake.socket"
  end
end
