defmodule Hyper.Node do
  @moduledoc """
  Per-machine supervisor. Exactly one `Hyper.Node` runs per BEAM node; it owns
  every microVM scheduled onto this machine.

  Children:

    * `Horde.Registry` (named `Hyper.Vm.Registry`) - a **cluster-wide** registry
      member. Maps `{vm_id, component}` -> pid; `node(pid)` answers "which machine
      owns this VM". Each node writes its own VMs; every node can read all of
      them. `members: :auto` joins peers over Distributed Erlang (wire up
      connectivity with libcluster).

    * `Hyper.Node.ImageStore` - a node-local content-addressed blob cache. Started
      before the VM supervisor so VMs can pull base images on boot.

    * `Hyper.Node.VMSupervisor` - a **local** `DynamicSupervisor` that starts one
      `Hyper.Node.FireVMM` per VM. Local on purpose: a firecracker VM is pinned to
      this machine's kernel/rootfs/cgroup/tap devices and cannot migrate, so we
      deliberately avoid `Horde.DynamicSupervisor` (which would try to restart
      VMs on a surviving node — cold-booting a ghost).

    * `Hyper.Node.Users` - manages an availability pool of users. Each VM gets its own user id
      and group id.
  """

  use Supervisor

  @registry Hyper.Vm.Registry
  @vm_sup Hyper.Node.VMSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Horde.Registry, name: @registry, keys: :unique, members: :auto},
      Hyper.Node.ImageStore,
      Hyper.Node.Users,
      {DynamicSupervisor, name: @vm_sup, strategy: :one_for_one},
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Start a microVM on THIS node."
  @spec start_vm(Hyper.Node.FireVMM.opts()) :: DynamicSupervisor.on_start_child()
  def start_vm(%{id: _} = opts) do
    DynamicSupervisor.start_child(@vm_sup, {Hyper.Node.FireVMM, opts})
  end

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.t()) :: node() | nil
  def whereis(vm_id) do
    case Horde.Registry.lookup(@registry, {vm_id, :supervisor}) do
      [{pid, _}] -> node(pid)
      [] -> nil
    end
  end

  @doc false
  def registry, do: @registry
end
