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
end

config :hyper,
  jailer_bin: "/opt/firecracker/jailer-v1.16.0-x86_64",
  firecracker_bin: "/opt/firecracker/firecracker-v1.16.0-x86_64",
  cgroup_parent: "hyper",
  jailer_chroot_base: "/srv/hyper/jails",
  socket_dir: "/srv/hyper/socks",
  scratch_dir: "/srv/hyper/scratch",
  uid_gid_range: {900_000, 999_999},
  layer_dir: "/srv/hyper/layers"

config :hyper, Hyper.Img.Db.Repo,
  database: "hyper_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10

# This node's total hard (alpha) budget - the memory and disk it contributes to the
# cluster, in bytes. The scheduler never places VMs whose summed alpha would exceed
# these. Tune per machine; override in runtime.exs from real hardware if desired.
config :hyper, Hyper.Node.Budget.Hard,
  mem: 8 * 1024 * 1024 * 1024,
  disk: 128 * 1024 * 1024 * 1024
