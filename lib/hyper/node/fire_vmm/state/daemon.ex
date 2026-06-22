defmodule Hyper.Node.FireVMM.State.Daemon do
  @moduledoc """
  Manages one microVM's firecracker daemon as an OS process living under the VM's
  per-VM `DynamicSupervisor` (`{id, :daemon_sup}`): launch it or stop it. It
  resolves the jailer command (the only place that needs to, since it's what
  launches the process) and otherwise knows nothing about the controller's state
  machine - `Hyper.Node.FireVMM.State` owns the monitor and decides *when* to
  call these.
  """

  alias Hyper.Node.FireVMM.Jailer
  alias Hyper.Node.FireVMM.Opts

  @type id :: Hyper.Vm.id()

  @doc """
  Launch the jailer OS process for `opts` under the VM's daemon supervisor and
  return its pid.

  The jailer creates the chroot (and the socket's parent dir) itself, so there is
  nothing to mkdir here. The child is `:temporary` (the controller, not the
  supervisor, decides relaunches) and runs under `MuonTrap.Daemon`, which kills
  the OS process when its port closes - on container teardown or BEAM death - so
  the daemon can never outlive its supervisor.
  """
  @spec start(Opts.t()) :: pid()
  def start(%Opts{vm_id: id} = opts) do
    cmd = Jailer.command(opts)

    spec =
      Supervisor.child_spec(
        {MuonTrap.Daemon, [cmd.binary, cmd.args, []]},
        id: :firecracker,
        restart: :temporary
      )

    {:ok, pid} = DynamicSupervisor.start_child(sup(id), spec)
    pid
  end

  @doc "Terminate the daemon `pid` running under `id`'s supervisor."
  @spec stop(id(), pid()) :: :ok | {:error, :not_found}
  def stop(id, pid) do
    DynamicSupervisor.terminate_child(sup(id), pid)
  end

  defp sup(id) do
    Hyper.Cluster.Routing.via({id, :daemon_sup})
  end
end
