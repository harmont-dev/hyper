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

  alias Hyper.Node.FireVMM
  alias Hyper.Node.Img
  alias Hyper.Node.Users
  alias Hyper.Node.Vmlinux

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

  @doc """
  Boot an image-backed VM on this node: claim a uid, build the mutable rootfs
  layer, resolve the kernel, and start the VM supervisor. The uid is freed and
  the mutable layer torn down automatically when the VM supervisor dies.
  """
  @spec start_image_vm(Hyper.Vm.Id.t(), Hyper.Vm.Spec.t()) :: {:ok, pid()} | {:error, term()}
  @decorate with_span("Hyper.Node.start_image_vm", include: [:vm_id, :spec])
  def start_image_vm(vm_id, %Hyper.Vm.Spec{} = spec) do
    with {:ok, uid} <- Users.claim(),
         {:ok, mutable} <- start_mutable_or_release(spec.img_id, vm_id, uid),
         kernel = Vmlinux.path(spec.arch),
         opts = build_opts(vm_id, spec, uid, mutable, kernel),
         {:ok, pid} <- start_vm_or_release(opts, uid, mutable) do
      # Bind the uid and the mutable layer to the VM supervisor's lifetime.
      :ok = Users.bind(uid, pid)
      :ok = Img.Mutable.acquire(mutable, pid)
      :ok = Img.Mutable.release(mutable)
      {:ok, pid}
    end
  end

  @doc "Tear down an image-backed VM started by `start_image_vm/2`."
  @spec stop_image_vm(pid()) :: :ok
  def stop_image_vm(pid) do
    case DynamicSupervisor.terminate_child(@vm_sup, pid) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end
  end

  @doc false
  @spec build_opts(Hyper.Vm.Id.t(), Hyper.Vm.Spec.t(), Users.id(), pid(), Path.t()) ::
          FireVMM.Opts.t()
  def build_opts(vm_id, %Hyper.Vm.Spec{} = spec, uid, mutable, kernel) do
    %FireVMM.Opts{
      vm_id: vm_id,
      uid: uid,
      gid: uid,
      type: spec.type,
      arch: spec.arch,
      mutable: mutable,
      kernel: kernel,
      boot_args: spec.boot_args
    }
  end

  @doc "Start a microVM on this node."
  @spec start_vm(FireVMM.Opts.t()) :: DynamicSupervisor.on_start_child()
  @decorate with_span("Hyper.Node.start_vm", include: [:opts])
  def start_vm(%FireVMM.Opts{} = opts) do
    DynamicSupervisor.start_child(@vm_sup, {FireVMM, opts})
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
    with {:ok, _} <- Hyper.Cfg.Budget.load(),
         :ok <- Hyper.Node.FireVMM.Provider.ensure_installed(),
         :ok <- Hyper.Node.FireVMM.VmLinux.Provider.ensure_installed(),
         :ok <- Hyper.Node.Vmlinux.test_system(),
         :ok <- Hyper.Img.OciLoader.Umoci.ensure_installed(),
         :ok <- Hyper.Img.OciLoader.test_system(),
         :ok <- Hyper.Node.Users.test_system(),
         :ok <- Hyper.Node.Layer.Repo.test_system(),
         :ok <- Hyper.SuidHelper.test_system(),
         {:ok, base} <- Hyper.SuidHelper.sys_test(),
         :ok <- check_helper_base(base) do
      Hyper.Node.FireVMM.test_system()
    end
  end

  @spec check_helper_base(Path.t()) ::
          :ok | {:error, {:suid_helper_base_mismatch, Path.t(), Path.t()}}
  defp check_helper_base(base) do
    if base == Hyper.Cfg.Dirs.work_dir() do
      :ok
    else
      {:error, {:suid_helper_base_mismatch, base, Hyper.Cfg.Dirs.work_dir()}}
    end
  end

  # Acquire the mutable layer on our own pid initially so it does not idle-reap
  # during boot; release on failure so it tears down.
  defp start_mutable_or_release(img_id, vm_id, uid) do
    case Img.create_mutable(img_id, vm_id) do
      {:ok, mutable} ->
        :ok = Img.Mutable.acquire(mutable)
        {:ok, mutable}

      {:error, reason} ->
        Users.release(uid)
        {:error, reason}
    end
  end

  defp start_vm_or_release(opts, uid, mutable) do
    case start_vm(opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Img.Mutable.release(mutable)
        Users.release(uid)
        {:error, reason}
    end
  end
end
