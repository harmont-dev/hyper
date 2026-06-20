defmodule Hyper.Node.FireVMM do
  @moduledoc """
  Supervises a single Firecracker microVM as `[daemon container, controller]`.

    1. `DynamicSupervisor` (`{id, :daemon_sup}`) - starts **empty**. The holding
       pen for the OS process (the `jailer`, which exec's firecracker). Launches
       nothing on its own, so no microVM exists until the controller commands it.
    2. `Hyper.Node.FireVMM.State` - the `:gen_statem` controller. It starts the
       jailer *into* the supervisor above (as a `:temporary` child) and monitors
       it. The state machine, not the supervisor, owns the daemon's lifecycle.

  `:rest_for_one`, container first:

    * controller crashes  -> only it restarts; the daemon survives and the
      controller re-adopts it (`State.ensure_daemon/1`). A controller bug does
      not kill a live, stateful VM.
    * container crashes    -> controller restarts too -> cold boot.
  """

  use Supervisor

  alias Hyper.Node.FireVMM.Client
  alias Hyper.Node.FireVMM.State

  @doc "The scheduler period of each VM."
  @spec cpu_period() :: Unit.Time.t()
  def cpu_period, do: Unit.Time.ms(100)

  defmodule Opts do
    @moduledoc "Options to pass into the jailer command."

    defstruct [:vm_id, :uid, :gid, :type]

    @type t :: %__MODULE__{
            vm_id: integer(),
            uid: Hyper.Node.Users.id(),
            gid: Hyper.Node.Users.id(),
            type: Hyper.Vm.Instance.t()
          }
  end

  @spec start_link(Opts.t()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: via(opts.vm_id))
  end

  def child_spec(opts) do
    # Keyed by VM id and :transient so a cleanly-stopped VM is not rebooted by
    # the node-level DynamicSupervisor.
    %{
      vm_id: {__MODULE__, opts.vm_id},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    # Resolve the jailer command (binary + args + the host-side socket the
    # controller will talk to) here, so neither the caller nor the controller
    # has to know host conventions. `Map.put_new` lets tests inject a stand-in
    # daemon (e.g. a sleeping shell) and an accessible socket path.
    cmd = Hyper.Node.FireVMM.Jailer.command(opts)

    vm_opts =
      opts
      |> Map.put_new(:binary, cmd.binary)
      |> Map.put_new(:args, cmd.args)
      |> Map.put_new(:socket_path, cmd.host_socket)

    children = [
      {DynamicSupervisor,
       name: Hyper.Cluster.Routing.via({opts.vm_id, :daemon_sup}), strategy: :one_for_one},
      {State, vm_opts},
      {Client,
       %Client.Opts{
         vm_id: opts.vm_id,
         socket_path: vm_opts.socket_path
       }}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp via(vm_id), do: Hyper.Cluster.Routing.via({vm_id, :supervisor})

  @doc "Test whether the system can run firecracker VMMs."
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    Hyper.Node.FireVMM.Jailer.test_system()
  end
end
