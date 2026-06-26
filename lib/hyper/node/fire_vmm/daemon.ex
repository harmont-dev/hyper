defmodule Hyper.Node.FireVMM.Daemon do
  @moduledoc """
  The jailed firecracker OS process for one microVM, as a static child of
  `Hyper.Node.FireVMM.Core`.

  Lifecycle is supervisor-owned. On every (re)start it first resets any stale
  jail left by a prior incarnation — the firecracker jailer refuses to reuse an
  existing chroot — then builds the jailer command and runs it under
  `MuonTrap.Daemon`, which kills the OS process when its port closes (controller
  crash, container teardown, or BEAM death). So no firecracker process outlives
  the supervisor, and `Core`'s `:one_for_all` restarting this child (e.g. after a
  firecracker crash) cleanly cold-boots against a fresh jail.

  The supervised process is `hyper-suidhelper jailer ...`, which `execve`s into
  the jailer (same pid) so MuonTrap owns the firecracker lifetime without needing
  to know the jailer path. `start_link/1` does the reset, then delegates and
  returns that pid.
  """

  alias Hyper.Node.FireVMM.{Jailer, Opts}
  alias Hyper.SuidHelper
  alias Unit.Time

  use OpenTelemetryDecorator

  require Logger

  @shutdown_timeout Time.s(5)

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

  @doc """
  Reset the VM's stale jail, then launch the jailer under `MuonTrap.Daemon` and
  return its pid. Fails (so the supervisor retries) if the reset cannot run.
  """
  @spec start_link(Opts.t()) :: {:ok, pid()} | {:error, term()}
  @decorate with_span("Hyper.Node.FireVMM.Daemon.start_link", include: [:id])
  def start_link(%Opts{vm_id: id} = opts) do
    with :ok <- SuidHelper.ChrootJail.remove(Jailer.chroot_dir(id), Jailer.cgroup_dir(id)) do
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
end
