defmodule Hyper.Cfg.Grpc do
  @moduledoc """
  gRPC server configuration, read from application env into a struct:

      config :hyper, Hyper.Cfg.Grpc,
        enabled: true,
        port: 50_051,
        cred: GRPC.Credential.new(ssl: [certfile: "/path/cert.pem", keyfile: "/path/key.pem"])

  Fields:

    * `:enabled` -- whether the server starts. Defaults to `false`.
    * `:port` -- the listen port. Defaults to `50051`.
    * `:cred` -- a `GRPC.Credential` for TLS, or `nil` (the default) for
      plaintext.
    * `:adapter_opts` -- options forwarded to the server adapter, e.g.
      `[ip: {0, 0, 0, 0}]`.

  Build the credential where you load your keys (e.g. `config/runtime.exs`);
  Hyper never reads the filesystem on your behalf.

  > #### Co-located nodes {: .info}
  >
  > Every node binds `:port`. Running multiple nodes on one host (e.g. a local
  > cluster) requires giving each a distinct port via its own config.
  """

  @default_port 50_051

  defstruct enabled: false, port: @default_port, cred: nil, adapter_opts: []

  @type t :: %__MODULE__{
          enabled: boolean(),
          port: :inet.port_number(),
          cred: GRPC.Credential.t() | nil,
          adapter_opts: keyword()
        }

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "Load the gRPC server configuration: config.exs > [grpc] toml > defaults."
  @spec load() :: t()
  def load do
    %__MODULE__{
      enabled: get_cfg(runtime: {__MODULE__, :enabled}, toml: "grpc.enabled", default: false),
      port: get_cfg(runtime: {__MODULE__, :port}, toml: "grpc.port", default: @default_port),
      cred: cred(get_cfg(runtime: {__MODULE__, :cred}, toml: "grpc.cred", default: nil)),
      adapter_opts:
        get_cfg(runtime: {__MODULE__, :adapter_opts}, toml: "grpc.adapter_opts", default: [])
    }
  end

  @spec cred(term()) :: GRPC.Credential.t() | nil
  defp cred(nil), do: nil
  defp cred(%GRPC.Credential{} = c), do: c

  defp cred(%{"cert" => cert, "key" => key}),
    do: GRPC.Credential.new(ssl: [certfile: cert, keyfile: key])

  @doc """
  The `GRPC.Server.Supervisor` options for this config: the endpoint and port,
  plus the TLS credential and adapter options when set.
  """
  @spec server_options(t()) :: keyword()
  def server_options(%__MODULE__{} = config) do
    [endpoint: Hyper.Grpc.Endpoint, port: config.port, start_server: true]
    |> put_unless(:cred, config.cred, nil)
    |> put_unless(:adapter_opts, config.adapter_opts, [])
  end

  @spec put_unless(keyword(), atom(), term(), term()) :: keyword()
  defp put_unless(opts, _key, skip, skip), do: opts
  defp put_unless(opts, key, value, _skip), do: Keyword.put(opts, key, value)
end
