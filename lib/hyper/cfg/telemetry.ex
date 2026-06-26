defmodule Hyper.Cfg.Telemetry do
  @moduledoc "Read-only view of the OpenTelemetry exporter config."

  @spec exporter :: atom()
  def exporter, do: Application.get_env(:opentelemetry, :traces_exporter, :none)

  @spec otlp_endpoint :: String.t() | nil
  def otlp_endpoint, do: Application.get_env(:opentelemetry_exporter, :otlp_endpoint)
end
