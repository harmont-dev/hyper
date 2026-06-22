defmodule Hyper.Node.FireVMM do
  @moduledoc """
  Supervises a single Firecracker microVM, split into two independent subtrees so
  no lifecycle invariant rides on the ordering of a flat child list:

    1. `Hyper.Node.FireVMM.Core` - the daemon container + `:gen_statem`
       controller, coupled under `:rest_for_one` (the daemon survives a
       controller restart). All order-sensitivity is contained there.
    2. `Hyper.Node.FireVMM.Client` - the API client. It depends only on `vm_id`
       (it derives the socket itself) and on nothing else in the tree, so it is
       an independent peer: its crashes don't disturb the core, and a core
       restart doesn't cycle it.

  Strategy is `:one_for_one`: the two subtrees are restarted independently.
  """

  use Supervisor

  alias Hyper.Node.FireVMM.Client
  alias Hyper.Node.FireVMM.Core

  @doc "The scheduler period of each VM."
  @spec cpu_period() :: Unit.Time.t()
  def cpu_period, do: Unit.Time.ms(100)

  defmodule Opts do
    @moduledoc "Options to pass into the jailer command."

    defstruct [:vm_id, :uid, :gid, :type, :source]

    @type t :: %__MODULE__{
            vm_id: Hyper.Vm.id(),
            uid: Hyper.Node.Users.id(),
            gid: Hyper.Node.Users.id(),
            type: Hyper.Vm.Instance.t(),
            source: Hyper.Vm.source()
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
    children = [
      # Client must be registered before Core: Core starts the State machine,
      # which calls Client.run while waiting for the daemon's API. Client depends
      # only on vm_id (an independent peer), so it has no reverse dependency.
      {Client, %Client.Opts{vm_id: opts.vm_id}},
      {Core, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp via(vm_id), do: Hyper.Cluster.Routing.via({vm_id, :supervisor})

  @doc "Test whether the system can run firecracker VMMs."
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    Hyper.Node.FireVMM.Jailer.test_system()
  end
end
