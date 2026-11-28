defmodule Hyper.GuestService.Relay do
  @moduledoc false

  @behaviour Hyper.GuestService.Handler

  alias Hyper.GuestService.{Conn, Handler}

  @type target :: pid() | {atom(), node()}
  @type state :: %{monitor: reference(), target: target()}

  @impl Handler
  @spec name() :: Hyper.GuestService.name()
  def name, do: "relay"

  @impl Handler
  @spec init(Conn.t(), target()) :: {:ok, state()}
  def init(conn, target) do
    monitor = Process.monitor(target)
    send(target, {:guest_service_open, self(), conn})
    {:ok, %{monitor: monitor, target: target}}
  end

  @impl Handler
  @spec handle_data(binary(), state()) :: {:continue, state()}
  def handle_data(data, state) do
    send(state.target, {:guest_service_data, self(), data})
    {:continue, state}
  end

  @impl Handler
  @spec handle_info(term(), state()) ::
          {:reply, iodata(), state()} | {:close, state()} | {:continue, state()}
  def handle_info({:guest_service_reply, data}, state), do: {:reply, data, state}
  def handle_info(:guest_service_close, state), do: {:close, state}

  def handle_info({:DOWN, monitor, :process, _target, _reason}, %{monitor: monitor} = state),
    do: {:close, state}

  def handle_info(_msg, state), do: {:continue, state}
end
