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

    * `Hyper.Node.Reaper` - a periodic, liveness-aware GC for per-VM host
      resources (orphaned firecracker cgroups and `hyper-rw-*` dm volumes) stranded
      by an unclean death whose vm_id never reboots. Started last so the VM
      supervisor it consults for liveness is already up.
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
      :ok ->
        # Clear any dm/loop devices a previous unclean shutdown left behind,
        # before the device-owning children start and collide with them.
        :ok = Hyper.Node.Reclaim.run()
        Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    children = [
      Hyper.Node.Users,
      # Layer owns Hyper.Node.Layer.Registry, which Budget.Advertiser queries
      # (via Hyper.Node.Layer.active/0) as it advertises on init - so Layer must
      # be up first.
      Hyper.Node.Layer,
      Hyper.Node.Budget.Supervisor,
      {DynamicSupervisor, name: @vm_sup, strategy: :one_for_one},
      Hyper.Node.Img,
      # Last child: :one_for_one starts in order, so the VM supervisor and Img are
      # up before the reaper's first tick can read their liveness.
      Hyper.Node.Reaper
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
         {:ok, mutable} <-
           acquire_or_release(uid, fn -> Img.create_mutable(spec.img_id, vm_id) end) do
      boot_with_mutable(vm_id, spec, uid, mutable)
    end
  end

  @doc """
  Boot a fork of the running `parent` VM (described by its start `Opts`) on this
  node: same image lineage, rootfs snapshotted COW-style from the parent's
  mutable layer.
  """
  @spec start_forked_vm(Hyper.Vm.Id.t(), FireVMM.Opts.t()) :: {:ok, pid()} | {:error, term()}
  @decorate with_span("Hyper.Node.start_forked_vm", include: [:child_vm_id])
  def start_forked_vm(child_vm_id, %FireVMM.Opts{} = parent) do
    spec = %Hyper.Vm.Spec{
      img_id: parent.img_id,
      type: parent.type,
      arch: parent.arch,
      boot_args: parent.boot_args
    }

    with {:ok, uid} <- Users.claim(),
         {:ok, mutable} <-
           acquire_or_release(uid, fn ->
             Img.create_fork(parent.img_id, parent.vm_id, child_vm_id)
           end) do
      boot_with_mutable(child_vm_id, spec, uid, mutable)
    end
  end

  # The shared boot tail: kernel + opts + VM supervisor, binding uid and mutable
  # to the supervisor's lifetime (previously inline in start_image_vm/2).
  @spec boot_with_mutable(Hyper.Vm.Id.t(), Hyper.Vm.Spec.t(), Users.id(), pid()) ::
          {:ok, pid()} | {:error, term()}
  defp boot_with_mutable(vm_id, spec, uid, mutable) do
    kernel = Vmlinux.path(spec.arch)
    opts = build_opts(vm_id, spec, uid, mutable, kernel)

    case start_vm_or_release(opts, uid, mutable) do
      {:ok, pid} ->
        :ok = Users.bind(uid, pid)
        :ok = Img.Mutable.acquire(mutable, pid)
        :ok = Img.Mutable.release(mutable)
        {:ok, pid}

      {:error, _} = err ->
        err
    end
  end

  # Start a mutable layer (plain or fork) holding it against idle-reap during
  # boot; on failure free the uid (generalizes start_mutable_or_release/3).
  @spec acquire_or_release(Users.id(), (-> {:ok, pid()} | {:error, term()})) ::
          {:ok, pid()} | {:error, term()}
  defp acquire_or_release(uid, start_fun) do
    case start_fun.() do
      {:ok, mutable} ->
        :ok = Img.Mutable.acquire(mutable)
        {:ok, mutable}

      {:error, reason} ->
        Users.release(uid)
        {:error, reason}
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

  @doc """
  Run `argv` in a VM hosted **on this node**, identified by `vm_id`, via its
  relay/agent. The node-local half of `Hyper.exec/3`, which resolves the owning
  node and `:erpc`-calls this function there.
  """
  @spec exec(Hyper.Vm.Id.t(), [String.t()], keyword()) ::
          {:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}
          | {:error, term()}
  def exec(vm_id, argv, opts \\ []) do
    Hyper.Node.FireVMM.Agent.exec(vm_id, argv, opts)
  end

  @doc """
  Fork the running VM `parent_vm_id` **onto this node**: budget-admitted like any
  placement (`try_run/3`), erroring with the node's admission verdict
  (`:mem_exhausted`, `:cpu_saturated`, ...) instead of falling back elsewhere.
  The guest is asked to `sync` first (best-effort); the snapshot is otherwise
  crash-consistent, like a power cut.
  """
  @spec fork_vm_local(Hyper.Vm.Id.t()) :: {:ok, pid()} | {:error, term()}
  @decorate with_span("Hyper.Node.fork_vm_local", include: [:parent_vm_id])
  def fork_vm_local(parent_vm_id) do
    with {:ok, parent} <- describe_vm(parent_vm_id) do
      _ = quiesce(parent_vm_id)
      child_vm_id = Hyper.Vm.Id.generate()
      spec = Hyper.Vm.Instance.spec(parent.type)

      try_run(child_vm_id, spec, fn -> start_forked_vm(child_vm_id, parent) end)
    end
  end

  @doc false
  # The start Opts of a VM running on this node; :not_found if it is gone
  # (describe/1 exits when the routing entry is dead).
  @spec describe_vm(Hyper.Vm.Id.t()) :: {:ok, FireVMM.Opts.t()} | {:error, :not_found}
  def describe_vm(vm_id) do
    {:ok, FireVMM.State.describe(vm_id)}
  catch
    :exit, _ -> {:error, :not_found}
  end

  # Best-effort guest page-cache flush before snapshotting; the fork is
  # crash-consistent regardless, so any failure (agent not up yet, timeout)
  # is deliberately ignored.
  @spec quiesce(Hyper.Vm.Id.t()) :: :ok
  defp quiesce(vm_id) do
    _ = exec(vm_id, ["/bin/sync"], timeout: 2_000)
    :ok
  end

  @doc """
  Publish the running VM `vm_id`'s disk state as a new derived image and return
  what a remote node needs to boot a fork of it: the new `img_id` plus the
  parent's instance `type`, `arch`, and `boot_args`. The slow-fork half of
  `Hyper.Vm.fork/1`; the parent keeps running throughout.
  """
  @spec publish_fork_image(Hyper.Vm.Id.t()) ::
          {:ok,
           %{
             img_id: Hyper.Img.id(),
             type: Hyper.Vm.Instance.t(),
             arch: Hyper.Vm.Instance.arch(),
             boot_args: String.t() | nil
           }}
          | {:error, term()}
  @decorate with_span("Hyper.Node.publish_fork_image", include: [:vm_id])
  def publish_fork_image(vm_id) do
    with {:ok, parent} <- describe_vm(vm_id) do
      _ = quiesce(vm_id)

      with {:ok, img_id} <- Img.Publish.fork_image(vm_id, parent.img_id) do
        {:ok,
         %{img_id: img_id, type: parent.type, arch: parent.arch, boot_args: parent.boot_args}}
      end
    end
  end

  @doc """
  CPU time accrued by `vm_id`'s meter **on this node** but not yet flushed to
  the usage table. The node-local half of `Hyper.usage/1`, which resolves the
  owning node and `:erpc`-calls this function there.
  """
  @spec unflushed_usage(Hyper.Vm.Id.t()) :: Unit.Time.t()
  def unflushed_usage(vm_id), do: FireVMM.Meter.unflushed(vm_id)

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
      img_id: spec.img_id,
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
  Admit `spec` on this node, then boot it.

  Capacity is leased BEFORE `start_fun` runs, so a refusal costs nothing
  physical and a concurrent herd cannot boot past the node's budget. The VM
  turns that lease into its own reservation from `Hyper.Node.FireVMM.init/1`,
  which `DynamicSupervisor.start_child` has already run by the time `start_fun`
  returns — so this function drops its lease unconditionally and never owns the
  reservation itself.
  """
  @spec try_run(Hyper.Vm.Id.t(), Hyper.Vm.Instance.Spec.t(), (-> {:ok, pid()} | {:error, term()})) ::
          {:ok, pid()} | {:error, term()}
  @decorate with_span("Hyper.Node.try_run", include: [:vm_id, :spec])
  def try_run(vm_id, spec, start_fun) do
    with {:ok, token} <- Hyper.Node.Budget.lease(vm_id, spec) do
      try do
        start_fun.()
      after
        release(vm_id, token)
      end
    end
  end

  # Dropping the lease must not turn a successful boot into a raise: `Hard` is a
  # single GenServer, so a restart or a queue timeout here would otherwise
  # propagate out of the `after` over a VM that is already live and claimed.
  # Swallowing is safe because the lease is monitored on this process too, and
  # this process exits as soon as `try_run/3` returns.
  @spec release(Hyper.Vm.Id.t(), reference()) :: :ok
  defp release(vm_id, token) do
    Hyper.Node.Budget.drop(vm_id, token)
  catch
    :exit, _ -> :ok
  end

  @spec test_system :: :ok | {:error, term()}
  def test_system do
    with {:ok, _} <- Hyper.Cfg.Budget.load(),
         :ok <- check_firecracker_bins(),
         :ok <- Hyper.Node.FireVMM.VmLinux.Provider.ensure_installed(),
         :ok <- Hyper.Node.Vmlinux.test_system(),
         :ok <- Hyper.Img.OciLoader.Umoci.ensure_installed(),
         :ok <- Hyper.Img.OciLoader.test_system(),
         :ok <- Hyper.Node.Users.test_system(),
         :ok <- Hyper.Node.Layer.Repo.test_system(),
         :ok <- Hyper.SuidHelper.test_system(),
         {:ok, base} <- Hyper.SuidHelper.sys_test(),
         :ok <- check_helper_base(base),
         :ok <- init_network() do
      Hyper.Node.FireVMM.test_system()
    end
  end

  # VM networking is mandatory: refuse to start unless `[network]` is
  # configured, then idempotently reconcile the host-wide `hyper` nftables
  # table. Runs after `Hyper.SuidHelper.test_system/0` so the helper is
  # confirmed present first.
  @spec init_network :: :ok | {:error, term()}
  defp init_network do
    if Hyper.Cfg.Network.configured?() do
      Hyper.SuidHelper.Network.host_init()
    else
      {:error, :network_not_configured}
    end
  end

  @spec check_firecracker_bins ::
          :ok
          | {:error, {:firecracker_bin_missing | :jailer_bin_missing, Path.t()}}
          | {:error, :firecracker_not_configured | :jailer_not_configured}
  defp check_firecracker_bins do
    with {:fc, {:ok, fc}} <- {:fc, Hyper.Cfg.Tools.firecracker_configured()},
         {:jail, {:ok, jail}} <- {:jail, Hyper.Cfg.Tools.jailer_configured()} do
      cond do
        not Sys.Posix.executable?(fc) -> {:error, {:firecracker_bin_missing, fc}}
        not Sys.Posix.executable?(jail) -> {:error, {:jailer_bin_missing, jail}}
        true -> :ok
      end
    else
      {:fc, :error} -> {:error, :firecracker_not_configured}
      {:jail, :error} -> {:error, :jailer_not_configured}
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

  @doc false
  # Public (not private) so the `:ignore` handling below is reachable from a
  # hermetic test without a real jail — `boot_with_mutable/4`'s only caller.
  @spec start_vm_or_release(FireVMM.Opts.t(), Users.id(), pid()) ::
          {:ok, pid()} | {:error, term()}
  def start_vm_or_release(opts, uid, mutable) do
    case start_vm(opts) do
      {:ok, pid} ->
        {:ok, pid}

      # `FireVMM.init/1` declines with `:ignore` when either step of its `with`
      # refuses: `Hyper.Cluster.Routing.register_self/1` finds the vm_id
      # already registered (a stale dead incarnation), or
      # `Hyper.Node.Budget.claim/2` has no lease left to claim (the lease
      # expired or its holder died mid-boot). Either way it is a refusal, not
      # a fault, but it must still hand back the uid and the mutable layer:
      # nothing else will, and a leaked uid is unrecoverable short of
      # restarting the node.
      :ignore ->
        Img.Mutable.release(mutable)
        Users.release(uid)
        {:error, :not_admitted}

      {:error, reason} ->
        Img.Mutable.release(mutable)
        Users.release(uid)
        {:error, reason}
    end
  end
end
