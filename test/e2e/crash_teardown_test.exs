defmodule Hyper.E2e.CrashTeardownTest do
  @moduledoc """
  Crash-reclaim contract: SIGKILLing the jailed Firecracker process behind a
  running VM must tear the whole VM down and reclaim its writable dm volume —
  monitors free the uid and mutable layer on :DOWN, and the Reaper (60 s
  tick, two-strike confirm) is the backstop for anything they miss. Nothing
  may resurrect the device (the idle-reaper-restart-resurrection regression).

  Runs only under `--only integration` on a provisioned host (see
  VmLifecycleTest for the environment contract).
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "SIGKILL of firecracker reclaims the dm volume and the routing entry" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)
    vm_id = Hyper.id(vm)
    assert vm_id, "Hyper.id/1 returned nil for a freshly-created VM"
    rw_dev = Hyper.Node.Img.Mutable.dm_name(vm_id)

    # Prove the VM is fully live first — otherwise the kill would race boot
    # and the test could pass without exercising crash reclaim at all.
    assert {:ok, %{exit_code: 0}} = await_exec(vm, ["/bin/true"])
    assert MapSet.member?(dm_devices(), rw_dev)

    # The jailer/firecracker cmdline carries the vm_id (--id); the BEAM's
    # own cmdline does not, so -f cannot match the test runner itself.
    assert {_, 0} = System.cmd("sudo", ["pkill", "-9", "-f", vm_id])

    # Monitor-driven teardown is immediate; the Reaper backstop is 60 s ticks
    # with two-strike confirmation, hence the generous deadline.
    assert poll_until(fn -> not MapSet.member?(dm_devices(), rw_dev) end, :timer.minutes(4)),
           "writable dm volume #{rw_dev} survived firecracker SIGKILL"

    assert poll_until(fn -> Hyper.whereis(vm_id) == nil end, :timer.minutes(1)),
           "routing entry for #{vm_id} survived firecracker SIGKILL"
  end
end
