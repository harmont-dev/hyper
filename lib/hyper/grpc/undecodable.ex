defmodule Hyper.Grpc.Undecodable do
  @moduledoc false

  @behaviour GRPC.Codec
  @behaviour GRPC.Server.Interceptor

  alias Hyper.Grpc.Codec

  @impl GRPC.Codec
  defdelegate name(), to: GRPC.Codec.Proto

  @impl GRPC.Codec
  defdelegate encode(struct, opts \\ []), to: GRPC.Codec.Proto

  # grpc_server decodes before any interceptor runs, outside the span that maps
  # a raised `GRPC.RPCError` to its status, so a raise here would reach the
  # client as UNKNOWN. Carry the failure to `call/4` instead.
  @impl GRPC.Codec
  def decode(binary, module) do
    GRPC.Codec.Proto.decode(binary, module)
  rescue
    e in Protobuf.DecodeError -> {__MODULE__, Exception.message(e)}
  end

  @impl GRPC.Server.Interceptor
  def init(opts), do: opts

  @impl GRPC.Server.Interceptor
  def call({__MODULE__, reason}, _stream, _next, _opts),
    do: raise(Codec.to_grpc({:error, {:undecodable, reason}}))

  def call(req, stream, next, _opts), do: next.(req, stream)
end
