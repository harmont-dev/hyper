import Config

# Per-node resource budget. Lives in runtime config because it builds `Unit.*`
# values, which are only loadable once the app's modules are on the code path.
config :hyper, Hyper.Cfg.Budget,
  mem_max: Unit.Information.gib(4),
  disk_max: Unit.Information.gib(4),
  cpu_max_load: 0.8,
  disk_bw_cap: Unit.Bandwidth.gibps(1),
  disk_bw_max_load: 0.8,
  net_bw_cap: Unit.Bandwidth.gibps(1),
  net_bw_max_load: 0.8

# Operator overrides from a well-known location. An optional Elixir config file
# at /etc/hyper/config.exs (override the path with HYPER_CONFIG) is merged in
# last, so its values win over every default set above. An absent file is a
# no-op — the normal case in dev and CI. Skipped under :test so the suite never
# reads host state.
#
# OpenTelemetry exporter wiring is resolved through Hyper.Cfg.Otel so that the
# operator's `config :hyper, Hyper.Cfg.Otel, ...` stanza (if present) takes
# precedence over the TOML table and environment variables.
if config_env() != :test do
  hyper_config = System.get_env("HYPER_CONFIG") || "/etc/hyper/config.exs"

  operator =
    if File.exists?(hyper_config), do: Config.Reader.read!(hyper_config, env: config_env()), else: []

  otel_exs = get_in(operator, [:hyper, Hyper.Cfg.Otel]) || []

  case Hyper.Cfg.Otel.exporter_options(otel_exs) do
    {:ok, opts} -> config :opentelemetry_exporter, opts
    :none -> config :opentelemetry, traces_exporter: :none
  end

  for {app, kw} <- operator, do: config(app, kw)
end
