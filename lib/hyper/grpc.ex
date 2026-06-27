defmodule Hyper.Grpc do
  @moduledoc """
  Public gRPC interface to a Hyper cluster.

  The service contract is `hyper.grpc.v0.Hyper` (see
  `proto/hyper/grpc/v0/hyper.proto`). Any gRPC client, in any language, can
  create, stop, locate, and list microVMs. Off-BEAM clients generate their own
  stubs from the `.proto`; BEAM clients can use the generated
  `Hyper.Grpc.V0.Hyper.Stub` together with `connect/2`.
  """

  alias Hyper.Cfg.Grpc, as: Config

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
