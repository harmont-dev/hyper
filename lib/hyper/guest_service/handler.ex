defmodule Hyper.GuestService.Handler do
  @moduledoc false

  @type action :: {:continue, term()} | {:reply, iodata(), term()} | {:close, term()}

  @callback name() :: Hyper.GuestService.name()
  @callback init(Hyper.GuestService.Conn.t(), arg :: term()) ::
              {:ok, state :: term()} | {:close, reason :: term()}
  @callback handle_data(binary(), state :: term()) :: action()
  @callback handle_info(term(), state :: term()) :: action()
  @callback terminate(reason :: term(), state :: term()) :: term()

  @optional_callbacks handle_info: 2, terminate: 2
end
