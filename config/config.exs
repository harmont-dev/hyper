import Config

# OpenTelemetry SDK: batch spans and ship them via OTLP.
# Runtime endpoint/headers are set in runtime.exs.
config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: %{service: %{name: System.get_env("OTEL_SERVICE_NAME", "hyper")}}

# Don't export spans during tests — keep the suite hermetic and offline.
if config_env() == :test do
  config :opentelemetry, traces_exporter: :none
end

# Firecracker jailer host config (see Hyper.Vm.Jailer). Defaults shown; override
# per host. The jailer + firecracker binaries and a delegated cgroup hierarchy
# must exist on the machine.
config :hyper,
  jailer_bin: "jailer",
  firecracker_bin: "/usr/bin/firecracker",
  jailer_chroot_base: "/srv/jailer",
  cgroup_parent: "hyper",
  jailer_uid: 1000,
  jailer_gid: 1000
