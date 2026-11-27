import Config

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp,
  resource: %{service: %{name: "hyper"}}

if config_env() == :test do
  config :opentelemetry, traces_exporter: :none

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
