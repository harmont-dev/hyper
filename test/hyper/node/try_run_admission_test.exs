defmodule Hyper.Node.TryRunAdmissionTest do
  @moduledoc """
  `Hyper.Node.try_run/4` is the node's authoritative admission gate: the
  scheduler picks a candidate from a stale gossip snapshot, and the target node
  confirms. Two different contracts hang off it, and only one is about the
  ledger.

    * **Ledger consistency** — admitted reservations never exceed `mem_max` /
      `disk_max`. `Hyper.Node.Budget.Hard` is a single GenServer, so this holds
      by serialization, and held even before the fix.

    * **Physical containment** — at no *instant* do more VMs exist on this
      machine than the budget admits, and a refused placement consumes no
      physical resources at all. The ledger is a proxy for real RAM; a VM that
      is running consumes it whether or not anything has reserved it.

  The second is what keeps the host off the OOM killer, and it is what these
  tests pin. `try_run/4` takes `start_fun`/`stop_fun` as arguments, so the boot
  window is observable without KVM: the fake boot parks, which is what a real
  firecracker boot (uid claim, dm-thin snapshot, jailer exec, guest init) does
  for hundreds of milliseconds.

  On the handoff tests: the fake `start_fun` calls `Hard.claim/2` because that is
  what `Hyper.Node.FireVMM.init/1` does for a real VM, and
  `DynamicSupervisor.start_child` returns only after a child's `init/1` has — so
  `{:ok, pid}` coming back from a real `start_fun` already implies the claim
  happened. The assertions are not on the fake: they are on whether `try_run`
  holds the reservation itself (it must not) and whether the ledger follows
  claims rather than boots (it must).
  """

  use ExUnit.Case, async: false
  use Unit.Operators

  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance.Spec
  alias Unit.Bandwidth
  alias Unit.Information

  @vm_mem Information.mib(128)
  @capacity 4
  @herd 12
  @boot_window_ms 400

  setup do
    saved = :persistent_term.get(Hyper.Cfg.Budget, :unset)
    :persistent_term.put(Hyper.Cfg.Budget, budget_config())

    on_exit(fn ->
      case saved do
        :unset -> :persistent_term.erase(Hyper.Cfg.Budget)
        config -> :persistent_term.put(Hyper.Cfg.Budget, config)
      end
    end)

    start_supervised!(Sys.Mon)
    start_supervised!(Hard)
    :ok
  end

  describe "physical containment under a herd" do
    test "never puts more VMs on the machine at once than the budget admits" do
      %{boots: boots} = run_herd()

      assert boots <= @capacity,
             """
             #{boots} VMs were simultaneously running on a node budgeted for #{@capacity}.
             #{boots} x #{Information.as_mib(@vm_mem)} MiB = \
             #{boots * Information.as_mib(@vm_mem)} MiB physically resident against a \
             #{Information.as_mib(budget_config().mem_max)} MiB cap.
             """
    end

    test "a refused placement never invokes start_fun" do
      %{boots: boots, results: results} = run_herd()

      assert Enum.count(results, &match?({:ok, _}, &1)) == @capacity

      assert boots == @capacity,
             "start_fun ran #{boots} times for #{@capacity} admissions: " <>
               "#{boots - @capacity} VMs were built only to be thrown away"
    end

    test "the ledger admits exactly the node's capacity" do
      %{results: results} = run_herd()

      assert Enum.count(results, &match?({:ok, _}, &1)) == @capacity
      assert Enum.count(results, &(&1 == {:error, :mem_exhausted})) == @herd - @capacity
    end
  end

  describe "lease lifetime around the boot" do
    test "a boot that fails releases the capacity it was granted" do
      before = Hard.headroom().mem

      assert {:error, :boom} =
               Hyper.Node.try_run("vm-fails", spec(), fn -> {:error, :boom} end)

      assert Hard.headroom().mem == before
    end

    test "a caller that dies mid-boot releases the capacity it was granted" do
      before = Hard.headroom().mem
      parent = self()

      caller =
        spawn(fn ->
          Hyper.Node.try_run("vm-abandoned", spec(), fn ->
            send(parent, :booting)
            Process.sleep(:infinity)
          end)
        end)

      assert_receive :booting
      assert Hard.headroom().mem == before - @vm_mem

      Process.exit(caller, :kill)

      assert eventually(fn -> Hard.headroom().mem == before end)
    end

    test "the reservation outlives the placing caller" do
      before = Hard.headroom().mem
      vm = spawn_idle()

      task =
        Task.async(fn ->
          Hyper.Node.try_run("vm-claims", spec(), fn ->
            :ok = Hard.claim("vm-claims", vm)
            {:ok, vm}
          end)
        end)

      assert {:ok, ^vm} = Task.await(task)

      # `try_run` has returned and its caller is gone. Had try_run held the
      # reservation against itself rather than dropping a lease, this releases.
      assert steadily(fn -> Hard.headroom().mem == before - @vm_mem end)
    end

    test "a boot that never claims leaves no reservation behind" do
      before = Hard.headroom().mem
      vm = spawn_idle()

      task =
        Task.async(fn ->
          Hyper.Node.try_run("vm-silent", spec(), fn -> {:ok, vm} end)
        end)

      assert {:ok, ^vm} = Task.await(task)

      # The ledger follows claims, not boots: nothing claimed, so once the
      # placing caller's lease is gone the capacity comes back rather than
      # lingering as an orphan entry.
      assert eventually(fn -> Hard.headroom().mem == before end)
    end
  end

  # Fire `@herd` concurrent placements at the node, holding every fake boot open
  # until the whole herd has arrived (or `@boot_window_ms` passes, so an
  # implementation that admits fewer than `@herd` does not hang).
  #
  # `boots` is both the number of `start_fun` invocations and the peak number of
  # concurrently-live VM processes, because every fake boot parks until released.
  defp run_herd do
    parent = self()

    callers =
      for i <- 1..@herd do
        Task.async(fn ->
          Hyper.Node.try_run("vm-herd-#{i}", spec(), boot(parent))
        end)
      end

    booted = await_boots(@herd, @boot_window_ms)
    for {caller, _vm} <- booted, do: send(caller, :release)

    results = Task.await_many(callers, 5_000)
    for {_caller, vm} <- booted, do: Process.exit(vm, :kill)

    %{boots: length(booted), results: results}
  end

  # Stands in for a real boot: a live process representing the VM's physical
  # footprint, announced to the test and held open for the duration of the boot.
  defp boot(parent) do
    fn ->
      vm = spawn_idle()
      send(parent, {:booted, self(), vm})

      receive do
        :release -> {:ok, vm}
      after
        @boot_window_ms -> {:ok, vm}
      end
    end
  end

  defp spawn_idle, do: spawn(fn -> Process.sleep(:infinity) end)

  defp await_boots(max, window_ms) do
    deadline = System.monotonic_time(:millisecond) + window_ms
    await_boots(max, deadline, [])
  end

  defp await_boots(0, _deadline, acc), do: acc

  defp await_boots(remaining, deadline, acc) do
    receive do
      {:booted, caller, vm} -> await_boots(remaining - 1, deadline, [{caller, vm} | acc])
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> acc
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
      disk: Information.gib(1),
      disk_bw: Bandwidth.mibps(1),
      net_bw: Bandwidth.mibps(1)
    }
  end

  # Memory is the only binding constraint: every other cap is set far out of
  # reach so the soft monitors' live readings cannot decide the outcome.
  defp budget_config do
    %Hyper.Cfg.Budget{
      mem_max: Information.mib(@capacity * Information.as_mib(@vm_mem)),
      disk_max: Information.tib(1),
      cpu_max_load: 1000.0,
      cpu_max_cap: nil,
      disk_bw_cap: Bandwidth.gibps(1000),
      disk_bw_max_load: 1.0,
      net_bw_cap: Bandwidth.gibps(1000),
      net_bw_max_load: 1.0,
      boot_lease_ttl: Unit.Time.s(300),
      restart_grace: Unit.Time.s(5)
    }
  end
end
