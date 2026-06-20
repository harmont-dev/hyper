import Config

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

# Layer GC: cluster-singleton that continuously walks the DB in batches and
# prunes blob rows whose data is no longer on the shared medium. Runs at low
# priority (small pages, paced, short per-statement timeout). The module ships
# these same defaults; this block exists for visibility and operator overrides.
config :hyper, Hyper.Img.Db.Gc,
  batch_size: 200,
  batch_pause_ms: 100,
  sweep_interval_ms: 60_000,
  acquire_interval_ms: 5_000,
  retry_ms: 60_000,
  statement_timeout_ms: 5_000
