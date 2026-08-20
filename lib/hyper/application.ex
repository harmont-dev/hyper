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

    topologies = Hyper.Cfg.Cluster.topologies()

    children =
      [
        # The image-lineage database. Started first so the rest of the node can
        # query images/leases on boot.
        Hyper.Img.Db.Repo,
        # Form the BEAM cluster (Distributed Erlang) so Horde's `members: :auto`
        # can discover peer nodes. Gossip strategy in dev - see config/config.exs.
        {Cluster.Supervisor, [topologies, [name: Hyper.ClusterSupervisor]]},
        # Cluster-wide CRDTs (VM routing + budget telemetry). Must precede
        # Hyper.Node so VM registrations and budget advertisements have their
        # registries on boot. Runs on every role: a client needs the routing +
        # budget registries to *read* peer state and schedule onto workers.
        Hyper.Cluster
      ] ++ role_children() ++ Hyper.Grpc.server_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Hyper.Supervisor)
  end

  # A :worker runs microVMs (Hyper.Node, which preflights KVM/Firecracker/the
  # setuid helper/networking). A :client is control-plane only: it never boots a
  # VM, so it starts neither Hyper.Node nor its privileged preflight, and instead
  # runs the autoscaler that provisions workers on demand.
  @spec role_children() :: [Supervisor.child_spec() | module()]
  defp role_children do
    case Hyper.Cfg.Role.get() do
      :worker -> [Hyper.Node]
      :client -> autoscale_children()
    end
  end

  @spec autoscale_children() :: [module()]
  defp autoscale_children do
    if Hyper.Cfg.Autoscale.enabled?(), do: [Hyper.Autoscale], else: []
  end
end
