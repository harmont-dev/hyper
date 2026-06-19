defmodule Hyper.Node do
  @moduledoc """
  Per-machine supervisor. Exactly one `Hyper.Node` runs per BEAM node; it owns
  every microVM scheduled onto this machine.

  Children:

    * `Horde.Repo` (named `Hyper.Vm.Repo`) - a **cluster-wide** registry
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
  use OpenTelemetryDecorator

  @registry Hyper.Vm.Repo
  @vm_sup Hyper.Node.VMSupervisor

  def start_link(opts \\ []) do
    case test_system() do
      :ok -> Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    children = [
      {Horde.Repo, name: @registry, keys: :unique, members: :auto},
      Hyper.Node.Users,
      {DynamicSupervisor, name: @vm_sup, strategy: :one_for_one},
      Hyper.Node.Layer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Start a microVM on this node."
  @spec start_vm(Hyper.Node.FireVMM.opts()) :: DynamicSupervisor.on_start_child()
  @decorate with_span("Hyper.Node.start_vm", include: [:opts])
  def start_vm(%{id: _} = opts) do
    DynamicSupervisor.start_child(@vm_sup, {Hyper.Node.FireVMM, opts})
  end

  @doc false
  def registry, do: @registry

  @spec test_system :: :ok | {:error, term()}
  def test_system do
    with :ok <- Hyper.Node.Users.test_system(),
         :ok <- Hyper.Node.Layer.Repo.test_system() do
      Hyper.Node.FireVMM.test_system()
    end
  end
end
