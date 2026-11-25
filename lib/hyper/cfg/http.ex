defmodule Hyper.Cfg.Http do
  @moduledoc """

  Http server configuration, read from application env into a struct:

      config :hyper, Hyper.Cfg.Http,
        enabled: true,
        port: 8081,
        http_server_opts: opts

  Fields:

    * `:enabled` -- whether the server starts. Defaults to `false`.
    * `:port` -- the listen port. Defaults to `8081`.
    * `:http_server_opts` -- options forwarded to the http server, e.g.
      `[ip: {0, 0, 0, 0}]`.

  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @default_port 8081

  defstruct enabled: false, port: @default_port, http_server_opts: []

  # Add the Credential after clarifying

  @type t :: %__MODULE__{
          enabled: boolean(),
          port: :inet.port_number(),
          http_server_opts: keyword()
        }

  @type ip_address :: :inet.ip4_address() | :inet.ip6_address()

  @doc "Load the Http server configuration: config.exs > [server] toml > defaults."
  @spec load() :: t()
  def load do
    %__MODULE__{
      enabled:
        get_cfg(runtime: {__MODULE__, :enabled}, toml: "http_server.enabled", default: false),
      port:
        get_cfg(runtime: {__MODULE__, :port}, toml: "http_server.port", default: @default_port),
      http_server_opts:
        get_cfg(
          runtime: {__MODULE__, :http_server_opts},
          toml: "http_server.options",
          default: []
        )
    }
  end

  @spec ip(term()) :: ip_address() | nil
  defp ip(nil), do: nil

  defp ip(ip) when is_binary(ip) do
    case :inet.parse_address(String.to_charlist(ip)) do
      {:ok, addr} -> addr
      {:error, _} -> nil
    end
  end

  defp ip(ip) when is_list(ip), do: ip |> List.to_tuple() |> ip()

  defp ip(ip) when is_tuple(ip) do
    case :inet.ntoa(ip) do
      {:error, _} -> nil
      _ -> ip
    end
  end

  defp ip(_), do: nil

  @doc """
  The `Http.Server.Supervisor` options for this config: the endpoint and port,
  and http server options when set.
  """
  @spec server_options(t()) :: keyword()
  def server_options(%__MODULE__{} = config) do
    base_opts =
      case config.http_server_opts do
        opts when is_map(opts) -> Enum.map(opts, fn {k, v} -> {to_atom(k), v} end)
        opts -> opts
      end

    options =
      base_opts
      |> Keyword.put(:port, config.port)
      |> Keyword.put(:ip, ip(Keyword.get(base_opts, :ip)) || {127, 0, 0, 1})

    [scheme: :http, plug: Hyper.Http.Router, options: options]
  end

  defp to_atom(k) when is_atom(k), do: k
  defp to_atom(k) when is_binary(k), do: String.to_atom(k)
end
