defmodule Hyper.Node.FireVMM.Core do
  @moduledoc """
  The lifecycle-coupled core of one microVM: the daemon container and its
  controller, restarted as a pair. Isolated from the API client
  (`Hyper.Node.FireVMM.Client`) so the *only* order-sensitive relationship in the
  VM tree lives in this two-child supervisor, where "daemon container first" is
  self-evident.

    1. `DynamicSupervisor` (`{vm_id, :daemon_sup}`) - starts **empty**, the
       holding pen for the jailer OS process (a `:temporary` child). MUST be the
       first child so it is registered before the controller launches into it.
    2. `Hyper.Node.FireVMM.State` - the `:gen_statem` controller; launches the
       jailer into the supervisor above and monitors it.

  `:one_for_all`, container first: a crash of *either* child takes both down and
  restarts the pair. So a controller crash also discards the daemon - no orphaned
  VM, and the fresh controller always cold-boots. The daemon is killed via
  `MuonTrap`, which terminates the OS process when its port closes (container
  teardown or BEAM death), so no firecracker process outlives the supervisor.

  A firecracker crash is a *separate* concern: the daemon is a `:temporary` child
  of the container, so it terminating does not trip this supervisor - the
  controller's monitor handles it in the `:crashed` state and relaunches.
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
    children = [
      {DynamicSupervisor,
       name: Hyper.Cluster.Routing.via({opts.vm_id, :daemon_sup}), strategy: :one_for_one},
      {State, opts}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
