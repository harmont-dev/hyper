defmodule Hyper.Node.FireVMM.GuestServices.Connection do
  @moduledoc false

  use GenServer, restart: :temporary

  alias Hyper.GuestService
  alias Hyper.GuestService.{Conn, Header}
  alias Hyper.Node.FireVMM.GuestServices.Listener
  alias Unit.{Information, Time}

  require Logger

  @header_timeout Time.s(5)
  @max_heap Information.mib(64)

  @spec start_link({pid(), Hyper.Vm.Id.t()}) :: GenServer.on_start()
  def start_link({listener, vm_id}), do: GenServer.start_link(__MODULE__, {listener, vm_id})

  @spec serve(pid(), :gen_tcp.socket()) :: :ok
  def serve(pid, socket), do: GenServer.cast(pid, {:serve, socket})

  @impl GenServer
  def init({listener, vm_id}) do
    Process.flag(:trap_exit, true)

    _ =
      Process.flag(:max_heap_size, %{
        size: div(Information.as_bytes(@max_heap), :erlang.system_info(:wordsize)),
        kill: true,
        error_logger: false,
        include_shared_binaries: true
      })

    timer = Process.send_after(self(), :header_timeout, Time.as_ms(@header_timeout))

    {:ok,
     %{listener: listener, vm_id: vm_id, socket: nil, header_timer: timer, phase: {:header, ""}}}
  end

  @impl GenServer
  def handle_cast({:serve, socket}, state), do: wait(%{state | socket: socket})

  @impl GenServer
  def handle_info({:tcp, socket, data}, %{socket: socket, phase: {:header, buffer}} = state) do
    case Header.parse(buffer <> data) do
      :more -> wait(%{state | phase: {:header, buffer <> data}})
      {:ok, name, rest} -> open(name, rest, state)
      {:error, _malformed} -> {:stop, :normal, state}
    end
  end

  def handle_info({:tcp, socket, data}, %{socket: socket, phase: {:serving, handler}} = state) do
    state |> call(:handle_data, [data, handler.state]) |> act(state)
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state), do: {:stop, :normal, state}

  def handle_info({:tcp_error, socket, _reason}, %{socket: socket} = state),
    do: {:stop, :normal, state}

  def handle_info(:header_timeout, %{phase: {:header, _buffer}} = state),
    do: {:stop, :normal, state}

  def handle_info(:header_timeout, state), do: {:noreply, state, timeout(state)}

  def handle_info(:timeout, %{phase: {:serving, _handler}} = state), do: {:stop, :normal, state}

  def handle_info(msg, %{phase: {:serving, handler}} = state) do
    if function_exported?(handler.mod, :handle_info, 2),
      do: state |> call(:handle_info, [msg, handler.state]) |> act(state),
      else: wait(state)
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(reason, state) do
    _ = handler_terminate(reason, state)
    _ = if state.socket, do: :gen_tcp.close(state.socket)
    :ok
  end

  @spec open(GuestService.name(), binary(), map()) ::
          {:noreply, map(), timeout()} | {:stop, :normal, map()}
  defp open(name, rest, state) do
    _ = Process.cancel_timer(state.header_timer)

    case Listener.admit(state.listener, name) do
      {:ok, service} -> start_handler(service, rest, state)
      _refused -> {:stop, :normal, %{state | phase: :closed}}
    end
  end

  @spec start_handler(GuestService.t(), binary(), map()) ::
          {:noreply, map(), timeout()} | {:stop, :normal, map()}
  defp start_handler(%GuestService{handler: {mod, arg}} = service, rest, state) do
    handler = %{
      mod: mod,
      name: service.name,
      idle_ms: Time.as_ms(service.idle_timeout),
      state: nil
    }

    state = %{state | phase: {:serving, handler}}

    case call(state, :init, [%Conn{vm_id: state.vm_id, service: service.name}, arg]) do
      {:ok, {:ok, handler_state}} -> state |> put_handler_state(handler_state) |> first_data(rest)
      {:ok, {:close, _reason}} -> {:stop, :normal, %{state | phase: :closed}}
      {:ok, other} -> state |> refuse({:bad_init, other}) |> closed()
      {:raised, kind, reason} -> state |> refuse({kind, reason}) |> closed()
    end
  end

  @spec first_data(map(), binary()) :: {:noreply, map(), timeout()} | {:stop, :normal, map()}
  defp first_data(state, ""), do: wait(state)

  defp first_data(%{phase: {:serving, handler}} = state, rest),
    do: state |> call(:handle_data, [rest, handler.state]) |> act(state)

  @spec call(map(), atom(), [term()]) :: {:ok, term()} | {:raised, atom(), term()}
  defp call(%{phase: {:serving, handler}}, fun, args) do
    {:ok, apply(handler.mod, fun, args)}
  catch
    kind, reason -> {:raised, kind, reason}
  end

  @spec act({:ok, term()} | {:raised, atom(), term()}, map()) ::
          {:noreply, map(), timeout()} | {:stop, :normal, map()}
  defp act({:ok, {:continue, handler_state}}, state),
    do: state |> put_handler_state(handler_state) |> wait()

  defp act({:ok, {:reply, data, handler_state}}, state) do
    state = put_handler_state(state, handler_state)

    case :gen_tcp.send(state.socket, data) do
      :ok -> wait(state)
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  defp act({:ok, {:close, handler_state}}, state),
    do: {:stop, :normal, put_handler_state(state, handler_state)}

  defp act({:ok, other}, state), do: refuse(state, {:bad_return, other})
  defp act({:raised, kind, reason}, state), do: refuse(state, {kind, reason})

  @spec refuse(map(), term()) :: {:stop, :normal, map()}
  defp refuse(%{phase: {:serving, handler}} = state, reason) do
    Logger.warning(
      "vm #{state.vm_id}: guest service #{handler.name}: handler failed: " <>
        inspect(reason, limit: 8, printable_limit: 256)
    )

    {:stop, :normal, state}
  end

  @spec closed({:stop, :normal, map()}) :: {:stop, :normal, map()}
  defp closed({:stop, reason, state}), do: {:stop, reason, %{state | phase: :closed}}

  @spec wait(map()) :: {:noreply, map(), timeout()} | {:stop, :normal, map()}
  defp wait(state) do
    case :inet.setopts(state.socket, active: :once) do
      :ok -> {:noreply, state, timeout(state)}
      {:error, _reason} -> {:stop, :normal, state}
    end
  end

  @spec timeout(map()) :: timeout()
  defp timeout(%{phase: {:serving, handler}}), do: handler.idle_ms
  defp timeout(_state), do: :infinity

  @spec put_handler_state(map(), term()) :: map()
  defp put_handler_state(%{phase: {:serving, handler}} = state, handler_state),
    do: %{state | phase: {:serving, %{handler | state: handler_state}}}

  @spec handler_terminate(term(), map()) :: {:ok, term()} | {:raised, atom(), term()} | :ok
  defp handler_terminate(reason, %{phase: {:serving, handler}} = state) do
    if function_exported?(handler.mod, :terminate, 2),
      do: call(state, :terminate, [reason, handler.state]),
      else: :ok
  end

  defp handler_terminate(_reason, _state), do: :ok
end
