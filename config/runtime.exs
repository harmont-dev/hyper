import Config

if config_env() != :test do
  case Hyper.Cfg.Otel.exporter_options() do
    {:ok, opts} -> config :opentelemetry_exporter, opts
    :none -> config :opentelemetry, traces_exporter: :none
  end

  if password = System.get_env("HYPER_DB_PASSWORD") do
    config :hyper, Hyper.Img.Db.Repo, password: password
  end
end
