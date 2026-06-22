defmodule Hyper.Node.FireVMM.Daemon do
  @moduledoc """
  The jailed firecracker OS process for one microVM, as a static child of
  `Hyper.Node.FireVMM.Core`.

  Lifecycle is supervisor-owned. On every (re)start it first resets any stale
  jail left by a prior incarnation - the firecracker jailer refuses to reuse an
  existing chroot - then builds the jailer command and runs it under
  `MuonTrap.Daemon`, which kills the OS process when its port closes (controller
  crash, container teardown, or BEAM death). So no firecracker process outlives
  the supervisor, and `Core`'s `:one_for_all` restarting this child (e.g. after a
  firecracker crash) cleanly cold-boots against a fresh jail.

  The supervised process *is* the `MuonTrap.Daemon` - `start_link/1` does the
  reset, then delegates and returns that pid.
  """

  alias Hyper.Node.FireVMM.{Jailer, Opts}
  alias Hyper.SuidHelper
  alias Unit.Time

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
  def start_link(%Opts{vm_id: id} = opts) do
    with :ok <- SuidHelper.ChrootJail.remove(Jailer.chroot_dir(id), Jailer.cgroup_dir(id)) do
      cmd = Jailer.command(opts)
      MuonTrap.Daemon.start_link(cmd.binary, cmd.args, [])
    end
  end
end
