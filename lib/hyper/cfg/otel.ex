defmodule Hyper.Cfg.Otel do
  @moduledoc """
  OpenTelemetry exporter configuration. Resolved from `config :hyper,
  Hyper.Cfg.Otel, proto:/endpoint:/headers:` (config.exs), the `[otel]` toml
  table, then the standard `OTEL_EXPORTER_OTLP_ENDPOINT` env var.
  `config/runtime.exs` calls `exporter_options/1` and feeds the result to
  `config :opentelemetry_exporter`.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "Resolve the `:opentelemetry_exporter` options, or `:none`."
  @spec exporter_options :: {:ok, keyword()} | :none
  def exporter_options do
    case pick("otel.endpoint") || env_endpoint() do
      nil ->
        :none

      ep ->
        {:ok,
         [
           otlp_protocol: proto(pick("otel.proto")),
           otlp_endpoint: ep,
           otlp_headers: headers(pick("otel.headers"))
         ]}
    end
  end

  @spec pick(String.t()) :: term() | nil
  defp pick(toml), do: get_cfg(toml: toml, default: nil)

  @spec proto(term()) :: :http_protobuf | :grpc
  defp proto("grpc"), do: :grpc
  defp proto(_), do: :http_protobuf

  @spec headers(term()) :: [{String.t(), String.t()}]
  defp headers(h) when is_map(h), do: Enum.map(h, fn {k, v} -> {k, to_string(v)} end)
  defp headers(_), do: []

  @spec env_endpoint() :: String.t() | nil
  defp env_endpoint, do: nonempty(System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT"))

  @spec nonempty(String.t() | nil) :: String.t() | nil
  defp nonempty(s) when is_binary(s) and s != "", do: s
  defp nonempty(_), do: nil
end
