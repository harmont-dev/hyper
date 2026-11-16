defmodule Hyper.Grpc.Endpoint do
  @moduledoc "The gRPC endpoint: logs each call and routes to `Hyper.Grpc.Server`."

  use GRPC.Endpoint

  intercept(GRPC.Server.Interceptors.Logger)
  intercept(Hyper.Grpc.Undecodable)

  run(Hyper.Grpc.Server)
end
