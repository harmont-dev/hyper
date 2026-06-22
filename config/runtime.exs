import Config

# Host data root. Single source of truth, shared with the setuid helper
# (native/suidhelper reads the same file with a root-ownership check). Falls back
# to a dev default when the file is absent - local dev / CI, where the helper is
# not installed anyway.
work_dir =
  case File.read("/etc/hyper/config.toml") do
    {:ok, body} -> body |> Toml.decode!() |> Map.fetch!("work_dir")
    {:error, _} -> "/srv/hyper"
  end

config :hyper, work_dir: work_dir

# Per-node resource budget. Lives in runtime config because it builds `Unit.*`
# values, which are only loadable once the app's modules are on the code path.
config :hyper, Hyper.Node.Config.Budget,
  mem_max: Unit.Information.gib(4),
  disk_max: Unit.Information.gib(4),
  cpu_max_load: 0.8,
  disk_bw_cap: Unit.Bandwidth.gibps(1),
  disk_bw_max_load: 0.8,
  net_bw_cap: Unit.Bandwidth.gibps(1),
  net_bw_max_load: 0.8

# Where to send traces. Defaults to Honeycomb; override OTEL_EXPORTER_OTLP_*
# to point at any OTLP/HTTP backend (Collector, Grafana, etc).
if config_env() != :test do
  endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "https://api.honeycomb.io")

  headers =
    case System.get_env("HONEYCOMB_API_KEY") do
      nil -> []
      "" -> []
      key -> [{"x-honeycomb-team", key}]
    end

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: endpoint,
    otlp_headers: headers
end
