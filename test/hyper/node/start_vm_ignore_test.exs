defmodule Hyper.Node.StartVmIgnoreTest do
  @moduledoc """
  Pins the merge-blocker fix in `Hyper.Node.start_vm_or_release/3`.

  `Hyper.Node.FireVMM.init/1` declines a boot with `:ignore` when its budget
  lease is gone by the time it tries to claim (expired ttl, or the leaser died
  mid-boot) — `Hyper.Node.Budget.claim/2` returns `{:error, :no_lease}` before
  any jailer/cgroup child is ever built. `DynamicSupervisor.start_child`
  propagates that `:ignore` verbatim, and `start_vm_or_release/3` must turn it
  into `{:error, _}` rather than crash on an unmatched case clause — a crash
  would skip the uid and mutable-layer release the ordinary `{:error, _}` arm
  performs, and `Hyper.Node.Users` has no other way to recover a leaked uid
  (see `TODO.txt`).

  Reachable hermetically because the decline happens before any real jail
  work: a dropped lease, a bare `DynamicSupervisor`, and `Hyper.Cluster.Routing`
  standing in for the app's supervision tree are enough to exercise the real
  `Hyper.Node.start_vm/1` call site.
  """

  use ExUnit.Case, async: false

  alias Hyper.Node.Budget.Hard
  alias Hyper.Node.Users
  alias Hyper.Vm.Instance.Spec, as: InstanceSpec
  alias Unit.Bandwidth
  alias Unit.Information

  @vm_mem Information.mib(128)
  @uid 100_000

  defmodule FakeMutable do
    @moduledoc false
    # Stands in for `Hyper.Node.Img.Mutable`: the declined-start path only ever
    # calls `release/1` on it, so that is the only call this needs to answer.
    use GenServer

    def start_link(_), do: GenServer.start_link(__MODULE__, nil)

    @impl true
    def init(_), do: {:ok, nil}

    @impl true
    def handle_call({:release, _pid}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    saved_budget = :persistent_term.get(Hyper.Cfg.Budget, :unset)
    saved_toml = Hyper.Cfg.Toml.reload()

    :persistent_term.put(Hyper.Cfg.Budget, budget_config())

    Hyper.Cfg.Toml.put_cache(Map.put(saved_toml, "jails", %{"uid_gid_range" => [@uid, @uid]}))

    on_exit(fn ->
      case saved_budget do
        :unset -> :persistent_term.erase(Hyper.Cfg.Budget)
        config -> :persistent_term.put(Hyper.Cfg.Budget, config)
      end

      Hyper.Cfg.Toml.put_cache(saved_toml)
    end)

    _ = Application.ensure_all_started(:horde)

    unless Process.whereis(Hyper.Cluster.Routing) do
      case start_supervised(Hyper.Cluster.Routing) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    start_supervised!(Users)
    start_supervised!(Hard)
    start_supervised!({DynamicSupervisor, name: Hyper.Node.VMSupervisor, strategy: :one_for_one})

    :ok
  end

  test "a lease dropped before FireVMM claims it declines the start without leaking the uid" do
    vm_id = "vm-declined-#{System.unique_integer([:positive])}"

    assert {:ok, token} = Hard.lease(vm_id, budget_spec())
    assert :ok = Hard.drop(vm_id, token)

    assert {:ok, uid} = Users.claim()
    assert uid == @uid

    {:ok, mutable} = start_supervised(FakeMutable)

    opts =
      Hyper.Node.build_opts(
        vm_id,
        %Hyper.Vm.Spec{img_id: "img-fake", type: :micro, arch: :x86_64},
        uid,
        mutable,
        "/dev/null"
      )

    assert {:error, :not_admitted} = Hyper.Node.start_vm_or_release(opts, uid, mutable)

    # The single configured uid must be back in the pool, not leaked.
    assert {:ok, ^uid} = Users.claim()
  end

  defp budget_spec do
    %InstanceSpec{
      vcpus: 0.25,
      mem: @vm_mem,
      disk: Information.mib(1),
      disk_bw: Bandwidth.mibps(1),
      net_bw: Bandwidth.mibps(1)
    }
  end

  defp budget_config do
    %Hyper.Cfg.Budget{
      mem_max: Information.gib(1),
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
