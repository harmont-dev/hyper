defmodule Hyper.Node.Budget.HardTest do
  @moduledoc """
  Process-level behaviour of `Hyper.Node.Budget.Hard` — the parts the pure
  ledger laws (`HardStatePropertiesTest`) cannot reach: monitors, the expiry
  sweep, and the grace that carries a reservation across a VM restart.

  A lease is released by three independent mechanisms, each covering what the
  others cannot:

    * the **monitor** on the leasing process — a crash, in microseconds;
    * the **TTL** — a leaser that is alive but wedged, which no monitor will
      ever fire for (an untimed `:erpc.call` into a hung `dmsetup` is the real
      case);
    * reconciliation — out of scope here.

  The TTL is deliberately generous in production: expiring a lease under a VM
  that is still legitimately booting produces an unaccounted running VM, which
  is the failure direction that reaches the OOM killer. Over-reserving only
  parks capacity. These tests shorten it to keep the suite fast.
  """

  use ExUnit.Case, async: false
  use Unit.Operators

  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance.Spec
  alias Unit.Bandwidth
  alias Unit.Information

  @vm_mem Information.mib(128)
  @capacity 4

  setup do
    saved = :persistent_term.get(Hyper.Cfg.Budget, :unset)

    on_exit(fn ->
      case saved do
        :unset -> :persistent_term.erase(Hyper.Cfg.Budget)
        config -> :persistent_term.put(Hyper.Cfg.Budget, config)
      end
    end)

    :ok
  end

  test "a lease that does not fit the node's caps is refused" do
    start_budget()
    fill_node()

    assert {:error, :mem_exhausted} = Hard.lease("vm-overflow", spec())
  end

  test "headroom counts an unclaimed lease, not just claimed reservations" do
    start_budget()
    before = Hard.headroom().mem

    assert {:ok, _token} = Hard.lease("vm-a", spec())

    assert Hard.headroom().mem == before - @vm_mem
  end

  test "an unclaimed lease is released when the leasing process dies" do
    start_budget()
    before = Hard.headroom().mem

    {leaser, {:ok, _token}} = lease_from_another_process("vm-a")
    assert Hard.headroom().mem == before - @vm_mem

    kill(leaser)

    assert eventually(fn -> Hard.headroom().mem == before end)
  end

  test "an unclaimed lease is released when its ttl expires, though the leaser lives" do
    start_budget(boot_lease_ttl: Unit.Time.ms(50))
    before = Hard.headroom().mem

    {leaser, {:ok, _token}} = lease_from_another_process("vm-wedged")
    assert Hard.headroom().mem == before - @vm_mem

    assert eventually(fn -> Hard.headroom().mem == before end, 200),
           "a wedged leaser held its lease past the ttl"

    assert Process.alive?(leaser), "the ttl must not depend on the leaser dying"
  end

  test "a claimed reservation survives the death of the process that leased it" do
    start_budget()
    before = Hard.headroom().mem

    {leaser, {:ok, _token}} = lease_from_another_process("vm-a")
    vm = spawn_idle()
    assert :ok = Hard.claim("vm-a", vm)

    kill(leaser)

    # The placing caller is gone; the VM is not. Its capacity must stay held.
    assert steadily(fn -> Hard.headroom().mem == before - @vm_mem end)
  end

  test "a claimed reservation is released once its owner dies and the grace elapses" do
    start_budget(restart_grace: Unit.Time.ms(50))
    before = Hard.headroom().mem

    {_leaser, {:ok, _token}} = lease_from_another_process("vm-a")
    vm = spawn_idle()
    assert :ok = Hard.claim("vm-a", vm)

    kill(vm)

    assert eventually(fn -> Hard.headroom().mem == before end, 200)
  end

  test "capacity is not released while a dead owner is inside the restart grace" do
    start_budget(restart_grace: Unit.Time.s(30))
    before = Hard.headroom().mem

    {_leaser, {:ok, _token}} = lease_from_another_process("vm-a")
    vm = spawn_idle()
    assert :ok = Hard.claim("vm-a", vm)
    kill(vm)

    # A `:transient` FireVMM restart briefly has no live owner. If the ledger
    # dipped here, a competing placement could take capacity the restarting VM
    # is about to reclaim — so a competing lease must still be refused.
    fill_node(from: 1)

    assert {:error, :mem_exhausted} = Hard.lease("vm-intruder", spec())
    assert Hard.headroom().mem == Information.zero()
    assert before != Information.zero()
  end

  test "re-claiming inside the restart grace rebinds the reservation to the new owner" do
    start_budget(restart_grace: Unit.Time.ms(500))
    before = Hard.headroom().mem

    {_leaser, {:ok, _token}} = lease_from_another_process("vm-a")
    first = spawn_idle()
    assert :ok = Hard.claim("vm-a", first)
    kill(first)

    restarted = spawn_idle()
    assert :ok = Hard.claim("vm-a", restarted)

    # The re-claim turned the grace lease back into a reservation, so the grace
    # deadline no longer applies: capacity is still held well past it. Were the
    # entry still a lease, it would expire at 500ms and this would fail.
    assert steadily(fn -> Hard.headroom().mem == before - @vm_mem end, 400)

    # Only the NEW owner's death releases it. Had the claim rebound to the dead
    # first owner's ref instead, this kill would match nothing and the capacity
    # would never come back.
    kill(restarted)
    assert eventually(fn -> Hard.headroom().mem == before end, 300)
  end

  test "dropping a lease with its token releases the capacity immediately" do
    start_budget()
    before = Hard.headroom().mem

    assert {:ok, token} = Hard.lease("vm-a", spec())
    assert Hard.headroom().mem == before - @vm_mem

    assert :ok = Hard.drop("vm-a", token)

    assert Hard.headroom().mem == before
  end

  test "dropping after the VM has claimed does not release the reservation" do
    start_budget()
    before = Hard.headroom().mem

    assert {:ok, token} = Hard.lease("vm-a", spec())
    vm = spawn_idle()
    assert :ok = Hard.claim("vm-a", vm)

    # The placing caller's normal post-boot drop must be a no-op now.
    assert :ok = Hard.drop("vm-a", token)

    assert steadily(fn -> Hard.headroom().mem == before - @vm_mem end)
  end

  test "claiming a vm_id with no lease is refused" do
    start_budget()

    assert {:error, :no_lease} = Hard.claim("vm-never-leased", spawn_idle())
  end

  defp start_budget(overrides \\ []) do
    :persistent_term.put(Hyper.Cfg.Budget, budget_config(overrides))
    start_supervised!(Hard)
  end

  # Lease from a process the test can kill without taking itself down, so the
  # monitor path is exercised for real rather than simulated.
  defp lease_from_another_process(vm_id) do
    test = self()

    {:ok, pid} =
      Task.start(fn ->
        send(test, {:leased, Hard.lease(vm_id, spec())})
        Process.sleep(:infinity)
      end)

    assert_receive {:leased, result}
    {pid, result}
  end

  defp spawn_idle, do: spawn(fn -> Process.sleep(:infinity) end)

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
    :ok
  end

  defp fill_node(opts \\ []) do
    from = Keyword.get(opts, :from, 0)

    for i <- from..(@capacity - 1) do
      assert {:ok, _token} = Hard.lease("vm-fill-#{i}", spec())
    end
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(2) && eventually(fun, attempts - 1)
    end
  end

  # The dual of `eventually`: the condition must hold for the whole window, so a
  # release that is merely late still fails the test.
  defp steadily(fun, attempts \\ 25) do
    cond do
      not fun.() -> false
      attempts == 0 -> true
      true -> Process.sleep(2) && steadily(fun, attempts - 1)
    end
  end

  defp spec do
    %Spec{
      vcpus: 0.25,
      mem: @vm_mem,
      disk: Information.mib(1),
      disk_bw: Bandwidth.mibps(1),
      net_bw: Bandwidth.mibps(1)
    }
  end

  # Memory is the only binding cap; everything else is set out of reach so a
  # refusal can only ever mean "the memory ledger refused".
  defp budget_config(overrides) do
    %Hyper.Cfg.Budget{
      mem_max: Information.mib(@capacity * Information.as_mib(@vm_mem)),
      disk_max: Information.tib(1),
      cpu_max_load: 1000.0,
      cpu_max_cap: nil,
      disk_bw_cap: Bandwidth.gibps(1000),
      disk_bw_max_load: 1.0,
      net_bw_cap: Bandwidth.gibps(1000),
      net_bw_max_load: 1.0,
      boot_lease_ttl: Keyword.get(overrides, :boot_lease_ttl, Unit.Time.s(300)),
      restart_grace: Keyword.get(overrides, :restart_grace, Unit.Time.s(5))
    }
  end
end
