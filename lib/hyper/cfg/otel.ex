defmodule Hyper.Cfg.Otel do
  @moduledoc """
  OpenTelemetry exporter configuration. Resolved from `config :hyper,
  Hyper.Cfg.Otel, proto:/endpoint:/headers:` (config.exs), the `[otel]` toml
  table, then the `HONEYCOMB_API_KEY` / `OTEL_EXPORTER_OTLP_ENDPOINT` env vars.
  `config/runtime.exs` calls `exporter_options/1` and feeds the result to
  `config :opentelemetry_exporter`.
  """

  import Hyper.Cfg, only: [fetch_cfg: 1]

  @honeycomb "https://api.honeycomb.io"

  @doc "Resolve the `:opentelemetry_exporter` options, or `:none`."
  @spec exporter_options(keyword()) :: {:ok, keyword()} | :none
  def exporter_options(exs) when is_list(exs) do
    endpoint = pick(exs, :endpoint, "otel.endpoint") || env_endpoint()

    case endpoint do
      nil ->
        :none

      ep ->
        {:ok,
         [
           otlp_protocol: proto(pick(exs, :proto, "otel.proto")),
           otlp_endpoint: ep,
           otlp_headers: headers(pick(exs, :headers, "otel.headers") || env_headers())
         ]}
    end
  end

  @spec pick(keyword(), atom(), String.t()) :: term() | nil
  defp pick(exs, key, toml) do
    case Keyword.fetch(exs, key) do
      {:ok, v} ->
        v

      :error ->
        case fetch_cfg(toml: toml),
          do: (
            {:ok, v} -> v
            :error -> nil
          )
    end
  end

  @spec proto(term()) :: :http_protobuf | :grpc
  defp proto(p) when p in [:http_protobuf, :grpc], do: p
  defp proto("grpc"), do: :grpc
  defp proto(_), do: :http_protobuf

  @spec headers(term()) :: [{String.t(), String.t()}]
  defp headers(h) when is_map(h), do: Enum.map(h, fn {k, v} -> {to_string(k), to_string(v)} end)
  defp headers(h) when is_list(h), do: Enum.map(h, fn {k, v} -> {to_string(k), to_string(v)} end)
  defp headers(_), do: []

  @spec env_endpoint() :: String.t() | nil
  defp env_endpoint do
    cond do
      nonempty(System.get_env("HONEYCOMB_API_KEY")) -> @honeycomb
      ep = nonempty(System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")) -> ep
      true -> nil
    end
  end

  @spec env_headers() :: [{String.t(), String.t()}]
  defp env_headers do
    case nonempty(System.get_env("HONEYCOMB_API_KEY")) do
      nil -> []
      key -> [{"x-honeycomb-team", key}]
    end
  end

  @spec nonempty(String.t() | nil) :: String.t() | nil
  defp nonempty(s) when is_binary(s) and s != "", do: s
  defp nonempty(_), do: nil
end
