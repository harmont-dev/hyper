defmodule Hyper.Node.FireVMM do
  @moduledoc """
  Supervises a single Firecracker microVM as `[daemon container, controller]`.

    1. `DynamicSupervisor` (`{id, :daemon_sup}`) — starts **empty**. The holding
       pen for the OS process (the `jailer`, which exec's firecracker). Launches
       nothing on its own, so no microVM exists until the controller commands it.
    2. `Hyper.Node.FireVMM.State` — the `:gen_statem` controller. It starts the
       jailer *into* the supervisor above (as a `:temporary` child) and monitors
       it. The state machine, not the supervisor, owns the daemon's lifecycle.

  `:rest_for_one`, container first:

    * controller crashes  → only it restarts; the daemon survives and the
      controller re-adopts it (`State.ensure_daemon/1`). A controller bug does
      not kill a live, stateful VM.
    * container crashes    → controller restarts too → cold boot.
  """

  use Supervisor

  alias Hyper.Node.FireVMM.State

  @typedoc """
  What the caller supplies: *what* to run, not *where*. The runtime paths, the
  jailer command and the host-side socket are derived here — see `init/1`.
  """
  @type opts :: %{
          required(:id) => String.t(),
          required(:source) => Hyper.vm_source(),
          required(:type) => Hyper.Vm.Instance.t()
        }

  @spec start_link(opts()) :: Supervisor.on_start()
  def start_link(%{id: id} = opts) do
    Supervisor.start_link(__MODULE__, opts, name: via(id))
  end

  def child_spec(%{id: id} = opts) do
    # Keyed by VM id and :transient so a cleanly-stopped VM is not rebooted by
    # the node-level DynamicSupervisor.
    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  @impl true
  def init(%{id: id} = opts) do
    # Resolve the jailer command (binary + args + the host-side socket the
    # controller will talk to) here, so neither the caller nor the controller
    # has to know host conventions. `Map.put_new` lets tests inject a stand-in
    # daemon (e.g. a sleeping shell) and an accessible socket path.
    cmd = Hyper.Vm.Jailer.command(opts)

    vm_opts =
      opts
      |> Map.put_new(:binary, cmd.binary)
      |> Map.put_new(:args, cmd.args)
      |> Map.put_new(:socket_path, cmd.host_socket)

    children = [
      {DynamicSupervisor,
       name: {:via, Horde.Registry, {Hyper.Node.Registry, {id, :daemon_sup}}}, strategy: :one_for_one},
      {State, vm_opts}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp via(id), do: {:via, Horde.Registry, {Hyper.Node.Registry, {id, :supervisor}}}
end
