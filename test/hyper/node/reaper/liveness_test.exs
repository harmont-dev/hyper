defmodule Hyper.Node.Reaper.LivenessTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.Img
  alias Hyper.Node.Img.Mutable
  alias Hyper.Node.Reaper.Plan

  setup do
    name = Img.mutable_registry()

    unless Process.whereis(name) do
      start_supervised!({Registry, keys: :unique, name: name})
    end

    :ok
  end

  defp register_live(vm_id) do
    test = self()

    {:ok, _pid} =
      Task.start_link(fn ->
        {:ok, _} = Registry.register(Img.mutable_registry(), vm_id, nil)
        send(test, {:registered, vm_id})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^vm_id}
  end

  test "a vm with a live mutable layer is never an orphan, even with a leftover rw device" do
    register_live("vm-live")

    live = MapSet.new(Mutable.active_vm_ids())

    # The reaper would see hyper-rw-vm-live in `dmsetup ls` (rw candidate) and no
    # cgroup leaf, yet the live mutable owner must protect it from reaping.
    assert Plan.orphans(live, [], ["vm-live"]) == MapSet.new([])
  end
end
