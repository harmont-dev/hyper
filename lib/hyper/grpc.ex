defmodule Hyper.Grpc do
  @moduledoc """
  Public gRPC interface to a Hyper cluster.

  The service contract is `hyper.grpc.v0.Hyper` (see
  `proto/hyper/grpc/v0/hyper.proto`). Any gRPC client, in any language, can
  create, stop, locate, and list microVMs. Off-BEAM clients generate their own
  stubs from the `.proto`; BEAM clients can use the generated
  `Hyper.Grpc.V0.Hyper.Stub` together with `connect/2`.

  > #### v0 {: .warning}
  >
  > This interface is unstable and may change without notice during early
  > development.

  ## Serving

  The server is always started by `Hyper.Application` -- it is a core interface,
  not an add-on, and an idle listener costs next to nothing. It is stateless and
  runs on every node; placement and routing are cluster-wide. See
  `Hyper.Grpc.Config` for configuration -- operators own the listener (port, TLS,
  adapter options) entirely from their own `config/`.

  ## Connecting from the BEAM

      {:ok, ch} = Hyper.Grpc.connect("hyper.example.com:50051", ca: "/etc/hyper/ca.pem")
      {:ok, reply} =
        Hyper.Grpc.V0.Hyper.Stub.create_vm(
          ch,
          %Hyper.Grpc.V0.CreateVmRequest{img_id: "img-abc"}
        )
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

  @doc """
  Connect a BEAM client channel to a Hyper gRPC endpoint at `addr`
  (`"host:port"`). Pass `ca:` (a PEM path) to verify the server's TLS
  certificate; omit it for an insecure (plaintext) connection.

  Defaults to `GRPC.Client.Adapters.Mint` (`:gun` is an optional dep not
  included in this project). Pass `adapter:` in `opts` to override; any other
  option is forwarded to `GRPC.Stub.connect/2`.
  """
  @spec connect(String.t(), keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def connect(addr, opts \\ []) do
    {ca, rest} = Keyword.pop(opts, :ca)
    stub_opts = Keyword.put_new(rest, :adapter, GRPC.Client.Adapters.Mint)

    case ca do
      nil ->
        GRPC.Stub.connect(addr, stub_opts)

      path ->
        GRPC.Stub.connect(
          addr,
          Keyword.put(stub_opts, :cred, GRPC.Credential.new(ssl: [cacertfile: path]))
        )
    end
  end
end
