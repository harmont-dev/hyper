import Config

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
