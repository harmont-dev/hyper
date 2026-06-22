defmodule Hyper.Node.FireVMM.State.Daemon do
  @moduledoc """
  Manages one microVM's firecracker daemon as an OS process living under the VM's
  per-VM `DynamicSupervisor` (`{id, :daemon_sup}`): launch it, adopt a survivor
  after a controller restart, or stop it. It resolves the jailer command (the
  only place that needs to, since it's what launches the process) and otherwise
  knows nothing about the controller's state machine - `Hyper.Node.FireVMM.State`
  owns the monitor and decides *when* to call these.
  """

  alias Hyper.Node.FireVMM.Jailer
  alias Hyper.Node.FireVMM.Opts

  @type id :: Hyper.Vm.id()

  @doc """
  The running daemon for `opts`: adopt a survivor (the controller restarted but
  the daemon lived) if one is registered, otherwise launch a fresh one. Returns
  its pid either way.
  """
  @spec ensure(Opts.t()) :: pid()
  def ensure(%Opts{vm_id: id} = opts) do
    case DynamicSupervisor.which_children(sup(id)) do
      [{_, pid, _, _}] when is_pid(pid) -> pid
      _ -> start(opts)
    end
  end

  @doc "Terminate the daemon `pid` running under `id`'s supervisor."
  @spec stop(id(), pid()) :: :ok | {:error, :not_found}
  def stop(id, pid) do
    DynamicSupervisor.terminate_child(sup(id), pid)
  end

  # The jailer creates the chroot (and thus the socket's parent dir) itself, so
  # there's nothing to mkdir here. MuonTrap just supervises the OS process; the
  # child is :temporary so the controller - not the supervisor - decides restarts.
  @spec start(Opts.t()) :: pid()
  defp start(%Opts{vm_id: id} = opts) do
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

  defp sup(id) do
    Hyper.Cluster.Routing.via({id, :daemon_sup})
  end
end
