defmodule Hyper.Cluster do
  @moduledoc """
  Owns this node's participation in the cluster-wide CRDTs: the VM routing
  registry (`Hyper.Cluster.Routing`) and the budget telemetry registry
  (`Hyper.Cluster.Budget`). One supervisor, one membership story, two
  independent DeltaCRDTs.

  Started once per BEAM node, before `Hyper.Node`, so VM registrations and budget
  advertisements have their registries available on boot.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [Hyper.Cluster.Routing, Hyper.Cluster.Budget]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
