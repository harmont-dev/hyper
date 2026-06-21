defmodule Hyper.Node.FireVMM.Core do
  @moduledoc """
  The lifecycle-coupled core of one microVM: the daemon container and its
  controller. Isolated from the API client (`Hyper.Node.FireVMM.Client`) so the
  *only* order-sensitive relationship in the VM tree lives in this two-child
  supervisor, where "daemon container first" is self-evident.

    1. `DynamicSupervisor` (`{vm_id, :daemon_sup}`) - starts **empty**, the
       holding pen for the jailer OS process. MUST be the first child.
    2. `Hyper.Node.FireVMM.State` - the `:gen_statem` controller; launches the
       jailer into the supervisor above (as a `:temporary` child) and monitors
       it. The state machine, not the supervisor, owns the daemon's lifecycle.

  `:rest_for_one`, container first:

    * controller crashes -> only it restarts; the daemon survives and the
      controller re-adopts it (`State.ensure_daemon/1`). A controller bug does
      not kill a live, stateful VM.
    * container crashes  -> controller restarts too -> cold boot.
  """

  use Supervisor

  alias Hyper.Node.FireVMM
  alias Hyper.Node.FireVMM.State

  @spec start_link(FireVMM.Opts.t()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Hyper.Cluster.Routing.via({opts.vm_id, :core}))
  end

  @impl true
  def init(opts) do
    # Resolve the jailer command (binary + args + host-side socket the controller
    # talks to) here, where the daemon lives, and hand the controller a fully
    # populated start struct.
    cmd = FireVMM.Jailer.command(opts)

    state_opts = %State.Opts{
      id: opts.vm_id,
      type: opts.type,
      source: opts.source,
      binary: cmd.binary,
      args: cmd.args,
      socket_path: cmd.host_socket
    }

    children = [
      {DynamicSupervisor,
       name: Hyper.Cluster.Routing.via({opts.vm_id, :daemon_sup}), strategy: :one_for_one},
      {State, state_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
