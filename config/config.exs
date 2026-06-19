import Config

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: %{service: %{name: "hyper"}}

# Distributed Erlang clustering. Static Epmd strategy for local dev: it connects
# to the node names listed below (no multicast). Start each node with a matching
# --name and a shared --cookie, e.g.
#
#     iex --name a@127.0.0.1 --cookie hyper -S mix
#     iex --name b@127.0.0.1 --cookie hyper -S mix
#
# Swap the strategy for prod (DNSPoll / EC2 tags).
config :libcluster,
  topologies: [
    hyper: [
      strategy: Cluster.Strategy.Epmd,
      config: [hosts: [:"a@127.0.0.1", :"b@127.0.0.1", :"c@127.0.0.1"]]
    ]
  ]

if config_env() == :test do
  config :opentelemetry, traces_exporter: :none
  # No cluster formation during tests.
  config :libcluster, topologies: []
  config :hyper, work_dir: Path.expand("../test/support/firecracker_work_dir", __DIR__)
end

config :hyper,
  work_dir: "/srv/hyper",
  cgroup_parent: "hyper",
  uid_gid_range: {900_000, 999_999},
  layer_dir: "/srv/hyper/layers"

config :hyper, Hyper.Img.Db.Repo,
  database: "hyper_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10
