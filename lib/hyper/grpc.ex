defmodule Hyper.Grpc do
  @moduledoc """
  Public gRPC interface to a Hyper cluster.

  The service contract is `hyper.grpc.v1.Machines` (see
  `priv/protos/hyper/grpc/v1/machines.proto`). Any gRPC client, in any language,
  can create, stop, locate, and list microVMs. Off-BEAM clients generate their
  own stubs from the `.proto`; BEAM clients can use the generated
  `Hyper.Grpc.V1.Machines.Stub` together with `connect/2`.

  ## Serving

  The server is started by `Hyper.Application` when `config :hyper, Hyper.Grpc,
  enabled: true`. It listens over TLS — set `:tls_cert` and `:tls_key` (PEM
  paths) and `:port`. It is stateless and runs on every node; placement and
  routing are cluster-wide.

  ## Connecting from the BEAM

      {:ok, ch} = Hyper.Grpc.connect("hyper.example.com:50051", ca: "/etc/hyper/ca.pem")
      {:ok, reply} =
        Hyper.Grpc.V1.Machines.Stub.create_machine(
          ch,
          %Hyper.Grpc.V1.CreateMachineRequest{img_id: "img-abc"}
        )
  """

  @doc """
  The supervisor children for the gRPC server: empty unless
  `config :hyper, Hyper.Grpc, enabled: true`. Spliced into the app supervision
  tree by `Hyper.Application`.
  """
  @spec server_children() :: [Supervisor.child_spec() | {module(), term()}]
  def server_children do
    config = Application.get_env(:hyper, __MODULE__, [])

    if Keyword.get(config, :enabled, false) do
      [grpc_child(config)]
    else
      []
    end
  end

  @doc """
  Connect a BEAM client channel to a Hyper gRPC endpoint at `addr`
  (`"host:port"`). Pass `ca:` (PEM path) to verify the server's TLS certificate;
  omit it for an insecure (plaintext) connection.
  """
  @spec connect(String.t(), keyword()) :: {:ok, GRPC.Channel.t()} | {:error, term()}
  def connect(addr, opts \\ []) do
    case Keyword.fetch(opts, :ca) do
      {:ok, ca} -> GRPC.Stub.connect(addr, cred: GRPC.Credential.new(ssl: [cacertfile: ca]))
      :error -> GRPC.Stub.connect(addr)
    end
  end

  @spec grpc_child(keyword()) :: {module(), keyword()}
  defp grpc_child(config) do
    port = Keyword.fetch!(config, :port)

    cred =
      GRPC.Credential.new(
        ssl: [
          certfile: Keyword.fetch!(config, :tls_cert),
          keyfile: Keyword.fetch!(config, :tls_key)
        ]
      )

    {GRPC.Server.Supervisor,
     endpoint: Hyper.Grpc.Endpoint, port: port, start_server: true, adapter_opts: [cred: cred]}
  end
end
