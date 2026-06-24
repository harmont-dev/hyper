defmodule Hyper.Grpc do
  @moduledoc """
  Public gRPC interface to a Hyper cluster.

  The service contract is `hyper.grpc.v0.Hyper` (see
  `proto/hyper/grpc/v0/hyper.proto`). Any gRPC client, in any language, can
  create, stop, locate, and list microVMs. Off-BEAM clients generate their own
  stubs from the `.proto`; BEAM clients can use the generated
  `Hyper.Grpc.V0.Hyper.Stub` together with `connect/2`.
  """

  defmodule Config do
    @moduledoc """
    gRPC server configuration, read from application env into a struct:

        config :hyper, Hyper.Grpc.Config,
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

    @doc "Load the gRPC server configuration from application env."
    @spec load() :: t()
    def load, do: struct!(__MODULE__, Application.get_env(:hyper, __MODULE__, []))

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

  @doc """
  The gRPC server's supervisor child, or `[]` when the server is disabled (the
  default). Spliced into the app supervision tree by `Hyper.Application`.
  """
  @spec server_children() :: [{module(), keyword()}]
  def server_children do
    config = Config.load()

    if config.enabled do
      [{GRPC.Server.Supervisor, Config.server_options(config)}]
    else
      []
    end
  end
end
