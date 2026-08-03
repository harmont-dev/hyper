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
        # registries on boot.
        Hyper.Cluster
      ] ++ host_children() ++ Hyper.Grpc.server_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: Hyper.Supervisor)
  end

  # `Hyper.Node` is what makes a machine able to run microVMs, and starting it
  # asserts the whole host stack exists (KVM, firecracker, the setuid helper,
  # `[network]`) through `Hyper.Node.test_system/0`. A `:control` node makes no
  # such claim and boots without any of it — see `Hyper.Cfg.Node`.
  @spec host_children() :: [Supervisor.child_spec() | module()]
  defp host_children do
    if Hyper.Cfg.Node.host?(), do: [Hyper.Node], else: []
  end
end
