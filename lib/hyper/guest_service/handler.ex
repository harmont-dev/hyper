defmodule Hyper.GuestService.Handler do
  @moduledoc """
  Behaviour for implementing `Hyper.GuestService`s.
  """

  @type action :: {:continue, term()} | {:reply, iodata(), term()} | {:close, term()}

  @doc """
  The name of this guest service.

  This is an address the VM can reach your service at, if the service is injected into the VM.
  """
  @callback name() :: Hyper.GuestService.name()

  @doc "Initialize the guest service. Called per VM."
  @callback init(Hyper.GuestService.Conn.t(), arg :: term()) ::
              {:ok, state :: term()} | {:close, reason :: term()}

  @doc """
  Handle a request (partial or complete) called by the VM.

  Returning `{:continue, term()}` allows you to fetch more data from the client.
  """
  @callback handle_data(binary(), state :: term()) :: action()

  @doc """
  Handle a message sent to the handler's process by something other than the VM.

  Returning `{:reply, iodata(), term()}` allows you to push data to the client without waiting
  for a request. If you don't implement this, the message is dropped.
  """
  @callback handle_info(term(), state :: term()) :: action()

  @doc "Called when the handler is torn down."
  @callback terminate(reason :: term(), state :: term()) :: term()

  @optional_callbacks handle_info: 2, terminate: 2
end
