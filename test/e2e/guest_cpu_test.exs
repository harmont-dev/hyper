defmodule Hyper.E2e.GuestCpuTest do
  @moduledoc """
  Live contract that a booted x86_64 guest sees no hardware-virtualization
  extension: `vmx` and `svm` are absent from its `/proc/cpuinfo` flags
  (`Hyper.Node.FireVMM.GuestCpu`).

  Only has teeth on a host whose KVM offers nested virt, which is the
  `kvm_intel`/`kvm_amd` default; a `nested=0` host passes either way. CI's
  `integration` runner keeps the default.

  Runs only under `--only integration` / `--include integration` on a host
  provisioned per docs/cookbook/install.md.
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  if Sys.Arch.current() != {:ok, :x86_64} do
    @moduletag skip: "VMX and SVM are x86 CPUID features"
  end

  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "a booted guest's CPU flags carry neither vmx nor svm" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)
    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)

    assert {:ok, %{stdout: flags, exit_code: 0}} =
             await_exec(
               vm,
               ["/bin/sh", "-c", "grep -m1 '^flags' /proc/cpuinfo"],
               :timer.seconds(120)
             )

    refute flags =~ ~r/\b(vmx|svm)\b/, "guest exposes a virtualization extension:\n#{flags}"
  end
end
