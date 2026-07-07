defmodule Hyper.E2e.VmLifecycleTest do
  @moduledoc """
  Live end-to-end contract of the VM lifecycle on a provisioned host:

  - `OciLoader.load/1` of a real registry image yields a bootable image id;
  - `create_vm/1` boots a guest whose per-VM writable dm volume
    (`Mutable.dm_name/1`) exists while the VM runs;
  - the guest agent answers `exec` with the command's captured output;
  - `stop_image_vm/1` reclaims the writable volume (no dm leak);
  - stopping flushes a final metering window: the VM's recorded compute
    (`Usage.total/1`) is positive, every `vm_usage` row is well-formed, and
    `total/3` over a range covering all windows equals the lifetime total.

  Runs only under `--only integration` / `--include integration` on a host
  provisioned per docs/cookbook/install.md (CI: the `integration` job).
  """
  use ExUnit.Case, async: false

  import Ecto.Query
  import Hyper.E2e

  alias Hyper.Img.Db.Repo
  alias Hyper.Metering.Usage
  alias Unit.Time

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  # public.ecr.aws mirrors library images without Docker Hub's per-IP pull
  # limits, which shared GHA egress IPs routinely exhaust.
  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "load -> create_vm -> exec -> stop reclaims the VM's dm volume" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    # :micro, not the :base default — :base asks for 32 GiB of disk budget,
    # which the default node budget (4 GiB) refuses with :no_capacity on the
    # small CI runner.
    assert {:ok, vm} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    # A failed assertion must not leak a live VM into the next E2E test in
    # the same run; stop_image_vm/1 is idempotent, so this is safe alongside
    # the explicit stop below (which is itself the behavior under test).
    on_exit(fn -> Hyper.Node.stop_image_vm(vm) end)

    vm_id = Hyper.id(vm)
    assert vm_id, "Hyper.id/1 returned nil for a freshly-created VM"
    rw_dev = Hyper.Node.Img.Mutable.dm_name(vm_id)

    assert MapSet.member?(dm_devices(), rw_dev),
           "expected writable dm volume #{rw_dev} while the VM is running"

    assert {:ok, %{stdout: out, exit_code: 0}} =
             await_exec(vm, ["/bin/echo", "hello from guest"])

    assert out =~ "hello from guest"

    assert :ok = Hyper.Node.stop_image_vm(vm)

    assert poll_until(fn -> not MapSet.member?(dm_devices(), rw_dev) end, :timer.seconds(90)),
           "writable dm volume #{rw_dev} leaked after stop_image_vm"

    # The Meter is the FireVMM supervisor's LAST child: at stop it terminates
    # first and flushes a final usage window while the cgroup still exists.
    # stop_image_vm/1 has returned, so the row should already be committed;
    # the poll only absorbs distributed-registry teardown stragglers.
    assert poll_until(fn -> Usage.total(vm_id) != nil end, :timer.seconds(30)),
           "no usage row after stop_image_vm — the teardown flush never landed"

    total = Usage.total(vm_id)
    assert Time.as_us(total) > 0

    rows = Repo.all(from(u in Usage, where: u.vm_id == ^vm_id))

    for row <- rows do
      assert DateTime.compare(row.window_start, row.window_end) == :lt,
             "usage window does not advance: #{inspect(row)}"

      assert row.cpu_usec > 0, "zero/negative usage window was recorded: #{inspect(row)}"
      assert row.node_id == to_string(node())
    end

    # total/3 buckets by window_start over a half-open range: a range covering
    # every window_start must reproduce the lifetime total exactly — an
    # off-by-one in the range predicate would double- or under-bill.
    starts = Enum.map(rows, & &1.window_start)
    from_ts = Enum.min(starts, DateTime)
    to_ts = DateTime.add(Enum.max(starts, DateTime), 1, :microsecond)
    assert Time.as_us(Usage.total(vm_id, from_ts, to_ts)) == Time.as_us(total)
  end
end
