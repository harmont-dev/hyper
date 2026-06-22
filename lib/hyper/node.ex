defmodule Hyper.Node do
  @moduledoc """
  Per-machine supervisor. Exactly one `Hyper.Node` runs per BEAM node; it owns
  every microVM scheduled onto this machine.

  Children:

    * VM routing lives in `Hyper.Cluster.Routing` (a cluster-wide CRDT started by
      `Hyper.Cluster`, above this supervisor), not here - this node only owns the
      *local* processes that run its microVMs.

    * `Hyper.Node.ImageStore` - a node-local content-addressed blob cache. Started
      before the VM supervisor so VMs can pull base images on boot.

    * `Hyper.Node.VMSupervisor` - a **local** `DynamicSupervisor` that starts one
      `Hyper.Node.FireVMM` per VM. Local on purpose: a firecracker VM is pinned to
      this machine's kernel/rootfs/cgroup/tap devices and cannot migrate, so we
      deliberately avoid `Horde.DynamicSupervisor` (which would try to restart
      VMs on a surviving node - cold-booting a ghost).

    * `Hyper.Node.Users` - manages an availability pool of users. Each VM gets its own user id
      and group id.

    * `Hyper.Node.Budget.Supervisor` - the node's resource budget: hard
      memory/disk accounting (`Hyper.Node.Budget.Hard`) plus the `Sys.Mon`
      real-time monitors backing the soft budget (`Hyper.Node.Budget.Soft`).
      Lives here, not at the application root, because both are per-node and only
      meaningful while this node hosts VMs.
  """

  use Supervisor
  use OpenTelemetryDecorator

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
      Hyper.Node.Users,
      Hyper.Node.Budget.Supervisor,
      {DynamicSupervisor, name: @vm_sup, strategy: :one_for_one},
      Hyper.Node.Layer,
      Hyper.Node.Img
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "Start a microVM on this node."
  @spec start_vm(Hyper.Node.FireVMM.opts()) :: DynamicSupervisor.on_start_child()
  @decorate with_span("Hyper.Node.start_vm", include: [:opts])
  def start_vm(%{id: _} = opts) do
    DynamicSupervisor.start_child(@vm_sup, {Hyper.Node.FireVMM, opts})
  end

  @doc """
  Start a VM here and confirm its budget.

  `start_fun` boots the VM and returns `{:ok, vm_pid}`; the reservation is held
  against `vm_pid` and released when it dies. If the reserve loses a race (the
  node filled up since the scheduler's snapshot) the just-started VM is torn down
  via `stop_fun` and `{:error, reason}` is returned.
  """
  @spec try_run(
          Hyper.Vm.Instance.Spec.t(),
          (-> {:ok, pid()} | {:error, term()}),
          (pid() -> :ok)
        ) :: {:ok, pid()} | {:error, term()}
  def try_run(spec, start_fun, stop_fun) do
    case start_fun.() do
      {:ok, pid} ->
        case Hyper.Node.Budget.admit(spec, pid) do
          :ok ->
            {:ok, pid}

          {:error, reason} ->
            :ok = stop_fun.(pid)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec test_system :: :ok | {:error, term()}
  def test_system do
    with {:ok, _} <- Hyper.Node.Config.Budget.load(),
         :ok <- Hyper.Node.FireVMM.Provider.ensure_installed(),
         :ok <- Hyper.Node.Vmlinux.test_system(),
         :ok <- Hyper.Node.Users.test_system(),
         :ok <- Hyper.Node.Layer.Repo.test_system(),
         :ok <- Sys.Linux.Dmsetup.test_system() do
      Hyper.Node.FireVMM.test_system()
    end
  end
end
