defmodule Hyper.Grpc do
  @moduledoc """
  Public gRPC interface to a Hyper cluster.

  The service contract is `hyper.grpc.v0.Machines` (see
  `proto/hyper/grpc/v0/hyper.proto`). Any gRPC client, in any language, can
  create, stop, locate, and list microVMs. Off-BEAM clients generate their own
  stubs from the `.proto`; BEAM clients can use the generated
  `Hyper.Grpc.V0.Machines.Stub` together with `connect/2`.

  > #### v0 {: .warning}
  >
  > This interface is unstable and may change without notice during early
  > development.

  ## Serving

  The server is always started by `Hyper.Application` — it is a core interface,
  not an add-on, and an idle listener costs next to nothing. It is stateless and
  runs on every node; placement and routing are cluster-wide. See
  `Hyper.Grpc.Config` for configuration — operators own the listener (port, TLS,
  adapter options) entirely from their own `config/`.

  ## Connecting from the BEAM

      {:ok, ch} = Hyper.Grpc.connect("hyper.example.com:50051", ca: "/etc/hyper/ca.pem")
      {:ok, reply} =
        Hyper.Grpc.V0.Machines.Stub.create_machine(
          ch,
          %Hyper.Grpc.V0.CreateMachineRequest{img_id: "img-abc"}
        )
  """

  defmodule Config do
    @moduledoc """
    gRPC server configuration, read from application env:

        config :hyper, Hyper.Grpc,
          port: 50_051,
          # any other GRPC.Server.Supervisor option, e.g. TLS:
          cred: GRPC.Credential.new(ssl: [certfile: "/path/cert.pem", keyfile: "/path/key.pem"])

    The server always runs (it is a core interface, not opt-in); this config
    only tunes the listener. Every key is passed straight through to
    `GRPC.Server.Supervisor`, so operators control port, TLS credentials,
    adapter options, and body limits entirely from their own config. Hyper
    prescribes nothing beyond defaulting `:port` and pointing the supervisor at
    `Hyper.Grpc.Endpoint`.

    Load secrets however you like: put cert/key paths in `config/runtime.exs` and
    build the credential there, or read them from a vault — Hyper never touches
    the filesystem on your behalf.

    > #### Co-located nodes {: .info}
    >
    > Every node binds `:port`. Running multiple nodes on one host (e.g. a local
    > cluster) requires giving each a distinct port via its own config.
    """

    @default_port 50_051

    @doc """
    Whether the gRPC server should start. Defaults to `true`.
    """
    @spec enabled?() :: boolean()
    def enabled?, do: Keyword.get(all(), :enabled, true)

    @doc """
    The options spliced into the `GRPC.Server.Supervisor` child: the operator's
    config (minus `:enabled`), with the endpoint, `start_server`, and a default
    port filled in if absent.
    """
    @spec server_options() :: keyword()
    def server_options do
      all()
      |> Keyword.delete(:enabled)
      |> Keyword.put_new(:endpoint, Hyper.Grpc.Endpoint)
      |> Keyword.put_new(:start_server, true)
      |> Keyword.put_new(:port, @default_port)
    end

    @spec all() :: keyword()
    defp all, do: Application.get_env(:hyper, __MODULE__, [])
  end

  @doc """
  The gRPC server's supervisor child. Always present — the server is a core
  interface, started unconditionally by `Hyper.Application`.
  """
  @spec server_children() :: [{module(), keyword()}]
  def server_children do
    if Config.enabled?() do
      [{GRPC.Server.Supervisor, Config.server_options()}]
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
