defmodule Hyper.E2e.VmLifecycleTest do
  @moduledoc """
  Live end-to-end contract of the VM lifecycle on a provisioned host:

  - `OciLoader.load/1` of a real registry image yields a bootable image id;
  - `create_vm/1` boots a guest whose per-VM writable dm volume
    (`Mutable.dm_name/1`) exists while the VM runs;
  - the guest agent answers `exec` with the command's captured output;
  - `stop_image_vm/1` reclaims the writable volume (no dm leak).

  Runs only under `--only integration` / `--include integration` on a host
  provisioned per docs/cookbook/install.md (CI: the `integration` job).
  """
  use ExUnit.Case, async: false

  import Hyper.E2e

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  # public.ecr.aws mirrors library images without Docker Hub's per-IP pull
  # limits, which shared GHA egress IPs routinely exhaust.
  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "load -> create_vm -> exec -> stop reclaims the VM's dm volume" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id})
    vm_id = Hyper.id(vm)
    rw_dev = Hyper.Node.Img.Mutable.dm_name(vm_id)

    assert MapSet.member?(dm_devices(), rw_dev),
           "expected writable dm volume #{rw_dev} while the VM is running"

    assert {:ok, %{stdout: out, exit_code: 0}} =
             await_exec(vm, ["/bin/echo", "hello from guest"])

    assert out =~ "hello from guest"

    assert :ok = Hyper.Node.stop_image_vm(vm)

    assert poll_until(fn -> not MapSet.member?(dm_devices(), rw_dev) end, :timer.seconds(90)),
           "writable dm volume #{rw_dev} leaked after stop_image_vm"
  end
end
