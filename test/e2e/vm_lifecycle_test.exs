defmodule Hyper.E2e.VmLifecycleTest do
  @moduledoc """
  Live end-to-end contract of the VM lifecycle on a provisioned host:

  - `OciLoader.load/1` of a real registry image yields a bootable image id;
  - `create_vm/1` boots a guest whose per-VM writable dm volume
    (`Mutable.dm_name/1`) exists while the VM runs;
  - the boot actually claims the node's hard budget: headroom drops by the
    instance type's `mem` while the VM runs, and comes back once it is stopped
    and `restart_grace` has elapsed — the one assertion this branch's central
    invariant (`Hyper.Node.FireVMM.init/1` claiming its lease) actually needs
    and did not have;
  - the guest agent answers `exec` with the command's captured output;
  - `stop_image_vm/1` reclaims the writable volume (no dm leak);
  - stopping flushes a final metering window: the VM's recorded compute
    (`Usage.total/1`) is positive, every `vm_usage` row is well-formed, and
    `total/3` over a range covering all windows equals the lifetime total.

  Runs only under `--only integration` / `--include integration` on a host
  provisioned per docs/cookbook/install.md (CI: the `integration` job).
  """
  use ExUnit.Case, async: false
  use Unit.Operators

  import Ecto.Query
  import Hyper.E2e

  alias Hyper.Img.Db.Repo
  alias Hyper.Metering.Usage
  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance
  alias Unit.Time

  @moduletag :integration
  @moduletag timeout: :timer.minutes(10)

  # public.ecr.aws mirrors library images without Docker Hub's per-IP pull
  # limits, which shared GHA egress IPs routinely exhaust.
  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  test "load -> create_vm -> exec -> stop reclaims the VM's dm volume" do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    mem_before = Hard.headroom().mem
    instance_mem = Instance.spec(:micro).mem

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

    # `create_vm/1` only returns once `FireVMM.init/1` has claimed this VM's
    # lease (`DynamicSupervisor.start_child` waits on `init/1`), so the drop is
    # visible immediately — no poll needed here, unlike the release below.
    assert Hard.headroom().mem == mem_before - instance_mem,
           "hard budget headroom did not drop by the booted instance's mem"

    assert {:ok, %{stdout: out, exit_code: 0}} =
             await_exec(vm, ["/bin/echo", "hello from guest"])

    assert out =~ "hello from guest"

    assert :ok = Hyper.Node.stop_image_vm(vm)

    assert poll_until(fn -> not MapSet.member?(dm_devices(), rw_dev) end, :timer.seconds(90)),
           "writable dm volume #{rw_dev} leaked after stop_image_vm"

    # A clean stop still turns the reservation back into a lease for
    # `restart_grace` (so a `:transient` FireVMM restart could reclaim it) —
    # it only actually expires once that grace elapses. 90s matches the other
    # polls in this test: generous headroom over the default 5s grace for a
    # runner busy with the rest of this job's E2E fleet.
    assert poll_until(fn -> Hard.headroom().mem == mem_before end, :timer.seconds(90)),
           "hard budget headroom did not return after stop_image_vm + restart_grace"

    # The Meter is the FireVMM supervisor's LAST child: at stop it terminates
    # first and flushes a final usage window while the cgroup still exists.
    # Because the meter baselines its accumulator at init (meter start), the
    # CPU the guest burned booting and answering exec is billed even when the
    # VM's whole life fits inside one sample interval — for a VM whose cgroup
    # is readable at meter start (this one booted and answered exec, so it
    # was), a positive usage row at stop is a meter guarantee, not a timing
    # bet.
    # stop_image_vm/1 has returned, so the row should already be committed;
    # the poll only absorbs distributed-registry teardown stragglers. Same 90s
    # budget as the dm-reclaim poll above: 30s has flaked twice on runners
    # busy with the rest of this job's E2E fleet.
    assert poll_until(fn -> Usage.total(vm_id) != nil end, :timer.seconds(90)),
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
