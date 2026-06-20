defmodule Hyper.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # :opentelemetry starts as its own OTP application (a dependency of :hyper),
    # so it is already running before this supervisor boots.
    #
    # Bridge Ecto's query telemetry into OpenTelemetry spans. The prefix matches
    # the repo's default telemetry_prefix (its module path, underscored).
    _ = OpentelemetryEcto.setup([:hyper, :img, :db, :repo])

    topologies = Application.get_env(:libcluster, :topologies, [])

    children = [
      # The image-lineage database. Started first so the rest of the node can
      # query images/leases on boot.
      Hyper.Img.Db.Repo,
      # Form the BEAM cluster (Distributed Erlang) so Horde's `members: :auto`
      # can discover peer nodes. Gossip strategy in dev - see config/config.exs.
      {Cluster.Supervisor, [topologies, [name: Hyper.ClusterSupervisor]]},
      # Cluster-wide CRDTs (VM routing + budget telemetry). Must precede
      # Hyper.Node so VM registrations and budget advertisements have their
      # registries on boot.
      Hyper.Cluster,
      Hyper.Node
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Hyper.Supervisor)
  end
end
