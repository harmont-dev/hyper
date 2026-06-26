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
  custom_endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
  api_key = System.get_env("HONEYCOMB_API_KEY")

  cond do
    api_key not in [nil, ""] ->
      config :opentelemetry_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint: custom_endpoint || "https://api.honeycomb.io",
        otlp_headers: [{"x-honeycomb-team", api_key}]

    custom_endpoint not in [nil, ""] ->
      # A custom OTLP backend (e.g. a local Collector) needs no Honeycomb key.
      config :opentelemetry_exporter,
        otlp_protocol: :http_protobuf,
        otlp_endpoint: custom_endpoint,
        otlp_headers: []

    true ->
      # No backend configured: exporting to the Honeycomb default with no key
      # 401s on every batch. Stay silent instead (typical for local dev). Set
      # HONEYCOMB_API_KEY or OTEL_EXPORTER_OTLP_ENDPOINT to enable tracing.
      config :opentelemetry, traces_exporter: :none
  end
end

# Operator overrides from a well-known location. An optional Elixir config file
# at /etc/hyper/config.exs (override the path with HYPER_CONFIG) is merged in
# last, so its values win over every default set above. An absent file is a
# no-op -- the normal case in dev and CI. Skipped under :test so the suite never
# reads host state.
if config_env() != :test do
  hyper_config = System.get_env("HYPER_CONFIG") || "/etc/hyper/config.exs"

  if File.exists?(hyper_config) do
    for {app, kw} <- Config.Reader.read!(hyper_config, env: config_env()) do
      config app, kw
    end
  end
end
