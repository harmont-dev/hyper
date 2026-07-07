import Config

# Operator overrides from a well-known location. An optional Elixir config file
# at /etc/hyper/config.exs (override the path with HYPER_CONFIG) is merged in
# as app env, which every `Hyper.Cfg.*` module treats as the highest-priority
# layer — above the `[budget]`-style TOML tables and above built-in defaults.
# An absent file is a no-op — the normal case in dev and CI. Skipped under
# :test so the suite never reads host state.
#
# OpenTelemetry exporter wiring is resolved through Hyper.Cfg.Otel so that the
# operator's `config :hyper, Hyper.Cfg.Otel, ...` stanza (if present) takes
# precedence over the TOML table and environment variables.
if config_env() != :test do
  hyper_config = System.get_env("HYPER_CONFIG") || "/etc/hyper/config.exs"

  operator =
    if File.exists?(hyper_config),
      do: Config.Reader.read!(hyper_config, env: config_env()),
      else: []

  otel_exs = get_in(operator, [:hyper, Hyper.Cfg.Otel]) || []

  case Hyper.Cfg.Otel.exporter_options(otel_exs) do
    {:ok, opts} -> config :opentelemetry_exporter, opts
    :none -> config :opentelemetry, traces_exporter: :none
  end

  for {app, kw} <- operator, do: config(app, kw)
end
