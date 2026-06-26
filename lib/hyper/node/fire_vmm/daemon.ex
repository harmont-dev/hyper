defmodule Hyper.Node.FireVMM.Daemon do
  @moduledoc """
  The jailed firecracker OS process for one microVM, as a static child of
  `Hyper.Node.FireVMM.Core`.

  A `trap_exit` GenServer that owns firecracker's lifetime end to end:

    * on every (re)start it resets any stale jail left by a prior incarnation —
      the firecracker jailer refuses to reuse an existing chroot — then launches
      the jailer under a linked `MuonTrap.Daemon`. The supervised process is
      `hyper-suidhelper jailer ...`, which `execve`s into the jailer (same pid).
    * if firecracker exits, the linked `MuonTrap.Daemon` exits and this server
      stops with that reason, so `Core`'s `:one_for_all` cold-boots the pair.
    * on teardown it **guarantees firecracker is dead**: `MuonTrap`'s port-close
      kills by process group, but the jailer `setsid`s firecracker into its own
      session, so it escapes that kill and would leak (holding the cgroup, the
      rootfs dm device, loop devices). `terminate/2` therefore runs the helper's
      `cgroup.kill` teardown (`ChrootJail.remove`), which SIGKILLs the whole leaf
      cgroup regardless of session. The same call on (re)start cleans up after a
      prior incarnation the BEAM could not (a SIGKILL'd node leaves no
      `terminate/2`); the periodic `Hyper.Node.Reaper` is the final backstop.
  """

  use GenServer
  use OpenTelemetryDecorator

  alias Hyper.Node.FireVMM.{Jailer, Opts}
  alias Hyper.SuidHelper
  alias Unit.Time

  require Logger

  @shutdown_timeout Time.s(5)

  defstruct [:opts, :muontrap]

  @spec child_spec(Opts.t()) :: Supervisor.child_spec()
  def child_spec(%Opts{} = opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      type: :worker,
      shutdown: Time.as_ms(@shutdown_timeout)
    }
  end

  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  @decorate with_span("Hyper.Node.FireVMM.Daemon.init", include: [:id])
  def init(%Opts{vm_id: id} = opts) do
    # Trap exits so the linked MuonTrap's exit reaches `handle_info` (not a silent
    # link kill) and so `terminate/2` runs on supervisor shutdown.
    Process.flag(:trap_exit, true)

    with :ok <- reset_stale_jail(id),
         {:ok, muontrap} <- launch(opts) do
      {:ok, %__MODULE__{opts: opts, muontrap: muontrap}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # firecracker (the linked MuonTrap.Daemon) exited: stop with its reason so
  # `Core`'s `:one_for_all` discards the controller too and cold-boots the pair.
  @impl true
  def handle_info({:EXIT, muontrap, reason}, %__MODULE__{muontrap: muontrap} = state) do
    {:stop, reason, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Guarantee firecracker is dead and its jail cleared. MuonTrap cannot kill the
  # setsid'd firecracker; the helper's `cgroup.kill` can. Best-effort: a failure
  # here is logged, and the `Reaper` will retry, but it must not crash teardown.
  @impl true
  @decorate with_span("Hyper.Node.FireVMM.Daemon.terminate", include: [:id])
  def terminate(_reason, %__MODULE__{opts: %Opts{vm_id: id}}) do
    case clear_jail(id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("vm #{id}: teardown failed to clear jail: #{inspect(reason)}")
    end
  end

  @spec reset_stale_jail(Hyper.Vm.id()) :: :ok | {:error, term()}
  defp reset_stale_jail(id), do: clear_jail(id)

  @spec clear_jail(Hyper.Vm.id()) :: :ok | {:error, term()}
  defp clear_jail(id) do
    SuidHelper.ChrootJail.remove(Jailer.chroot_dir(id), Jailer.cgroup_dir(id))
  end

  @spec launch(Opts.t()) :: {:ok, pid()} | {:error, term()}
  defp launch(%Opts{vm_id: id} = opts) do
    cmd = Jailer.command(opts)

    # Surface what the jailed process actually does: `log_output` routes the
    # helper/jailer/firecracker stdout+stderr (guest serial console included)
    # to the Logger, and `exit_status_to_reason` turns MuonTrap's opaque
    # `:error_exit_status` into `{:firecracker_exited, status}` so a crash
    # report names the real exit code instead of hiding it.
    daemon_opts = [
      log_output: :info,
      log_prefix: "vm #{id} firecracker: ",
      stderr_to_stdout: true,
      exit_status_to_reason: &{:firecracker_exited, &1}
    ]

    case MuonTrap.Daemon.start_link(cmd.binary, cmd.args, daemon_opts) do
      {:ok, pid} ->
        Logger.info("vm #{id}: jailer launched under MuonTrap (#{inspect(pid)})")
        {:ok, pid}

      {:error, reason} = err ->
        Logger.error("vm #{id}: jailer failed to launch: #{inspect(reason)}")
        err
    end
  end
end
