defmodule Hyper.E2e.GuestMemoryPressureTest do
  @moduledoc """
  A guest that fills its RAM with page cache and then exhausts it is handled by
  the guest's own OOM killer, never the host's: the VM keeps its boot (Core
  would cold-boot a host-killed Firecracker, so an answering agent alone proves
  nothing), the agent still answers, and the guest's dmesg records the kill.

  Runs only under `--only integration` on a host provisioned per
  docs/cookbook/install.md.
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "a guest out of RAM OOM-kills its own process and keeps running" do
    {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)

    boot_id = ["/bin/cat", "/proc/sys/kernel/random/boot_id"]
    assert {:ok, %{exit_code: 0, stdout: booted}} = await_exec(vm, boot_id, :timer.minutes(3))

    fill = ["/bin/dd", "if=/dev/zero", "of=/root/fill", "bs=1M", "count=300", "conv=fsync"]
    assert {:ok, %{exit_code: 0}} = Hyper.exec(vm, fill, timeout: :timer.minutes(3))

    bomb = ["/bin/sh", "-c", ~S|awk 'BEGIN { s = "x"; while (1) s = s s }'; echo $?|]

    assert {:ok, %{exit_code: 0, stdout: "137\n"}} =
             Hyper.exec(vm, bomb, timeout: :timer.minutes(2))

    assert {:ok, %{exit_code: 0, stdout: ^booted}} = Hyper.exec(vm, boot_id, timeout: 10_000)
    assert {:ok, %{exit_code: 0, stdout: dmesg}} = Hyper.exec(vm, ["/bin/dmesg"], timeout: 10_000)
    assert dmesg =~ ~r/Killed process \d+ \(awk\)/
  end
end
