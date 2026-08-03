defmodule Hyper.Cluster do
  @moduledoc """
  Owns this node's participation in the cluster-wide CRDTs: the VM routing
  registry (`Hyper.Cluster.Routing`) and the budget telemetry registry
  (`Hyper.Cluster.Budget`). One supervisor, one membership story, two
  independent DeltaCRDTs.

  Started once per BEAM node, before `Hyper.Node`, so VM registrations and budget
  advertisements have their registries available on boot.

  Children, in start order:

    * `Hyper.Cluster.Routing` - the VM routing registry. First, because it doubles
      as the namespace every cluster singleton below elects itself in.

    * `Hyper.Cluster.Budget` - the budget telemetry registry each node advertises
      its `Hyper.Node.Budget.NodeState` into.

    * `Hyper.Img.Db.Gc` - the cluster-singleton that continuously prunes blob rows
      whose data is no longer on the shared medium.

    * `Hyper.Cluster.Fleet.Supervisor` - a `Horde.DynamicSupervisor` holding one
      controller per *machine* in the fleet. Horde on purpose, and precisely the
      inverse of the reasoning behind the local `Hyper.Node.VMSupervisor`: a
      microVM is welded to its host and must never be restarted elsewhere, but a
      machine exists at its provider no matter which BEAM node is watching it, so
      its controller *should* migrate to a survivor when the watching node dies.
      Machines are the one resource here that outlives the node observing it.

    * `Hyper.Cluster.Fleet.Governor` - the cluster-singleton that decides how many
      machines the fleet should have. Last: it elects itself through a key in
      `Hyper.Cluster.Routing`, reads `Hyper.Cluster.Budget` to measure headroom,
      and adopts machines by starting children under `Fleet.Supervisor`, so all
      three must already be up when its first tick lands.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Hyper.Cluster.Routing,
      Hyper.Cluster.Budget,
      Hyper.Img.Db.Gc,
      Hyper.Cluster.Fleet.Supervisor,
      Hyper.Cluster.Fleet.Governor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
