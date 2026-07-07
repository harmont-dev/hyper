defmodule Hyper.E2e.CrashRecoveryTest do
  @moduledoc """
  Crash-recovery contract: SIGKILLing the jailed Firecracker process behind a
  running VM must NOT kill the VM. `Core`'s `:one_for_all` deliberately
  cold-boots the daemon + controller pair on the same mutable rootfs
  (lib/hyper/node/fire_vmm/core.ex), so the guest comes back and answers
  `exec` again on the SAME writable dm volume — proven not just by the dm
  device name still existing post-recovery (a destroy+recreate under the same
  deterministic name would also pass that check) but by a file written to the
  guest's rootfs before the crash still being there after recovery, which only
  survives if the underlying block device itself was preserved. Reclaim
  happens only on explicit stop: `stop_image_vm/1` must then remove the
  volume — the crash/recover cycle must not leak the device or the routing
  entry past the stop. Metering must survive the cycle too: the recreated
  cgroup's counter reset re-baselines the accumulator instead of going
  negative, so the final flush at stop still lands a positive usage total.

  Runs only under `--only integration` on a provisioned host (see
  VmLifecycleTest for the environment contract).
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  alias Hyper.Metering.Usage
  alias Unit.Time

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "SIGKILL of firecracker cold-boots the VM; explicit stop reclaims the volume" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    # :micro, not the :base default — :base asks for 32 GiB of disk budget,
    # which the default node budget (4 GiB) refuses with :no_capacity on the
    # small CI runner.
    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    # A failed assertion anywhere below must not leak a live VM into other
    # tests in the same run; stop_image_vm/1 treats :not_found as :ok, so
    # this is safe alongside the explicit stop the test itself performs.
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)
    vm_id = Hyper.id(vm)
    assert vm_id, "Hyper.id/1 returned nil for a freshly-created VM"
    rw_dev = Hyper.Node.Img.Mutable.dm_name(vm_id)

    # Prove the VM is fully live first — otherwise the kill would race boot
    # and the test could pass without exercising crash recovery at all. The
    # second guest of a run has come up slower than the first on nested-virt
    # CI runners, hence the extended deadline. The marker write doubles as the
    # volume-identity proof: `sync` forces it past the page cache (which dies
    # with firecracker) and onto the dm volume itself, so it can only survive
    # the crash if that volume — not just a same-named replacement — does.
    assert {:ok, %{exit_code: 0}} =
             await_exec(
               vm,
               ["/bin/sh", "-c", "echo persisted > /marker && sync"],
               :timer.minutes(3)
             )

    assert MapSet.member?(dm_devices(), rw_dev)

    # The jailer/firecracker cmdline carries the vm_id (--id). The [v]...
    # bracket regex still matches it, but not this command's own sudo wrapper —
    # whose cmdline contains the pattern text, not the raw id (a bare -f vm_id
    # SIGKILLs its own sudo and System.cmd reports 137 instead of 0).
    kill_pattern = "[" <> String.first(vm_id) <> "]" <> String.slice(vm_id, 1..-1//1)
    assert {_, 0} = System.cmd("sudo", ["pkill", "-9", "-f", kill_pattern])

    # Self-heal: Core cold-boots the daemon/controller pair; the relay child
    # is untouched, so exec reaches the rebooted guest once its agent is back.
    assert {:ok, %{stdout: marker, exit_code: 0}} =
             await_exec(vm, ["/bin/cat", "/marker"], :timer.minutes(3)),
           "VM did not recover from a firecracker SIGKILL"

    assert marker =~ "persisted",
           "recovered VM lost pre-crash writes — not the same volume"

    # The recovered VM still runs on ITS OWN volume — the crash must not have
    # torn it down or swapped it. Supplementary to the marker-file assertion
    # above: this only proves the dm device name persisted, which a
    # destroy+recreate under the same deterministic name would also satisfy.
    assert MapSet.member?(dm_devices(), rw_dev),
           "writable dm volume #{rw_dev} vanished across the crash/recovery cycle"

    assert :ok = Hyper.Node.stop_image_vm(vm)

    assert poll_until(fn -> not MapSet.member?(dm_devices(), rw_dev) end, :timer.seconds(90)),
           "writable dm volume #{rw_dev} leaked after stop_image_vm"

    assert poll_until(fn -> Hyper.whereis(vm_id) == nil end, :timer.minutes(1)),
           "routing entry for #{vm_id} survived stop_image_vm"

    # The crash recreated the VM's cgroup, resetting cpu.stat to zero. A
    # naive delta would go negative, every flush would then be refused by
    # the cpu_usec > 0 validation, and no usage row would ever land — so a
    # positive lifetime total proves the accumulator re-baselined and the
    # meter kept billing across the crash.
    assert poll_until(fn -> Usage.total(vm_id) != nil end, :timer.seconds(30)),
           "no usage recorded across the crash/recovery cycle"

    assert Time.as_us(Usage.total(vm_id)) > 0
  end
end
