import Config

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: %{service: %{name: "hyper"}}

if config_env() == :test do
  config :opentelemetry, traces_exporter: :none
end

config :hyper,
  jailer_bin: "/opt/firecracker/jailer-v1.16.0-x86_64",
  firecracker_bin: "/opt/firecracker/firecracker-v1.16.0-x86_64",
  cgroup_parent: "hyper",
  jailer_chroot_base: "/srv/hyper/jails",
  socket_dir: "/srv/hyper/socks",
  uid_gid_range: {900000, 999999}
