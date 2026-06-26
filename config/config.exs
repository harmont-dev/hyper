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

  # JUnit XML for Codecov Test Analytics. A fixed report_dir (not the default
  # app_path) gives CI a stable path; automatic_create_dir? mkdirs it since
  # the formatter uses File.write! which won't create parents. include_* embed
  # the source file + line so Codecov can link failures back to the test.
  config :junit_formatter,
    report_dir: "_build/test",
    report_file: "junit.xml",
    print_report_file: true,
    include_filename?: true,
    include_file_line?: true,
    automatic_create_dir?: true
end

config :hyper, Hyper.Img.Db.Repo,
  database: "hyper_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10
