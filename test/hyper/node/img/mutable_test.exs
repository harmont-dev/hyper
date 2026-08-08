defmodule Hyper.Node.Img.MutableTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.Img
  alias Hyper.Node.Img.Mutable

  setup do
    # The full app does not start in the test env, so stand up just the registry
    # the mutable layers register into. Reuse the real name so we exercise the
    # exact lookup `active_vm_ids/0` performs.
    name = Img.mutable_registry()

    unless Process.whereis(name) do
      start_supervised!({Registry, keys: :unique, name: name})
    end

    :ok
  end

  defp register_live(vm_id) do
    test = self()

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, _} = Registry.register(Img.mutable_registry(), vm_id, nil)
        send(test, {:registered, vm_id})
        Process.sleep(:infinity)
      end)

    assert_receive {:registered, ^vm_id}
    pid
  end

  test "active_vm_ids lists the vm_ids of every live mutable layer" do
    register_live("vm-a")
    register_live("vm-b")

    assert Enum.sort(Mutable.active_vm_ids()) == ["vm-a", "vm-b"]
  end

  test "active_vm_ids drops a vm_id once its mutable layer dies" do
    pid = register_live("vm-gone")
    ref = Process.monitor(pid)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    # Registry removes the entry on the registered process's :DOWN. Poll briefly
    # so the test is robust to that async unregister without a fixed sleep.
    assert eventually(fn -> Mutable.active_vm_ids() == [] end)
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(2)
        eventually(fun, attempts - 1)
    end
  end

  describe "volume_sectors/2" do
    test "grows the volume to the instance type's disk" do
      # The writable volume was sized to the read-only image, so a guest got a
      # filesystem exactly as large as its own contents and Docker could not
      # pull anything into it. The instance type's disk is what the VM was
      # admitted against, so it is what the VM should actually get.
      origin = Unit.Information.as_sectors(Unit.Information.mib(566))

      assert Mutable.volume_sectors(origin, Unit.Information.gib(16)) ==
               Unit.Information.as_sectors(Unit.Information.gib(16))
    end

    test "never shrinks below the image it overlays" do
      # The volume is an external-origin snapshot of the read-only image;
      # sizing it under the origin would truncate the rootfs rather than
      # merely give the guest less room.
      origin = Unit.Information.as_sectors(Unit.Information.gib(4))

      assert Mutable.volume_sectors(origin, Unit.Information.mib(64)) == origin
    end

    test "falls back to the image size when no disk is given" do
      origin = Unit.Information.as_sectors(Unit.Information.mib(566))

      assert Mutable.volume_sectors(origin, nil) == origin
    end
  end
end
