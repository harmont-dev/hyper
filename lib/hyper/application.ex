defmodule Hyper.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # :opentelemetry starts as its own OTP application (a dependency of :hyper),
    # so it is already running before this supervisor boots.
    #
    # Bridge Ecto's query telemetry into OpenTelemetry spans. Both concrete
    # repos set telemetry_prefix: [:hyper, :img, :db, :repo] in config, so this
    # call is valid for whichever backend is active.
    _ = OpentelemetryEcto.setup([:hyper, :img, :db, :repo])

    topologies = Application.get_env(:libcluster, :topologies, [])

    children =
      [
        # The image-lineage database. Started first so the rest of the node can
        # query images/leases on boot.
        Hyper.Img.Db.Backend.repo(),
        # Form the BEAM cluster (Distributed Erlang) so Horde's `members: :auto`
        # can discover peer nodes. Gossip strategy in dev - see config/config.exs.
        {Cluster.Supervisor, [topologies, [name: Hyper.ClusterSupervisor]]},
        # Cluster-wide CRDTs (VM routing + budget telemetry). Must precede
        # Hyper.Node so VM registrations and budget advertisements have their
        # registries on boot.
        Hyper.Cluster,
        Hyper.Node
      ] ++ sqlite_guard_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Hyper.Supervisor)
  end

  defp sqlite_guard_children do
    if Hyper.Img.Db.Backend.sqlite?() do
      [Hyper.Img.Db.SingleNodeGuard]
    else
      []
    end
  end
end
