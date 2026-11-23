defmodule Hyper.Node.FireVMM.GuestServices.Listener do
  @moduledoc false

  use GenServer, restart: :temporary, shutdown: 10_000

  alias Hyper.GuestService
  alias Hyper.Node.FireVMM.GuestServices.Connection
  alias Hyper.Node.FireVMM.Jailer
  alias Unit.Time

  require Logger

  @max_connections 64
  @accepts_per_second 32
  @backlog 1024
  @send_timeout_ms 30_000
  @accept_backoff Time.ms(100)

  defmodule Opts do
    @moduledoc false

    @enforce_keys [:vm_id, :services]
    defstruct [:vm_id, :services]

    @type t :: %__MODULE__{
            vm_id: Hyper.Vm.Id.t(),
            services: [GuestService.t()]
          }
  end

  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts), do: GenServer.start_link(__MODULE__, opts)

  @spec admit(pid(), GuestService.name()) :: {:ok, GuestService.t()} | :unknown | :full
  def admit(listener, name), do: GenServer.call(listener, {:admit, name})

  @impl GenServer
  def init(%Opts{vm_id: vm_id, services: services}) do
    Process.flag(:trap_exit, true)
    path = Jailer.host_guest_socket(vm_id)
    _ = File.rm(path)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, path},
        active: false,
        backlog: @backlog,
        send_timeout: @send_timeout_ms,
        send_timeout_close: true
      ])

    :ok = File.chmod(path, 0o600)

    {:ok, conns} =
      DynamicSupervisor.start_link(strategy: :one_for_one, max_children: @max_connections)

    {:ok,
     %{
       vm_id: vm_id,
       path: path,
       listen: listen,
       conns: conns,
       services: Map.new(services, &{&1.name, &1}),
       admitted: %{}
     }, {:continue, :accept}}
  end

  @impl GenServer
  def handle_continue(:accept, state) do
    listener = self()
    _ = spawn_link(fn -> accept_loop(state, listener, {nil, 0}, false) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call({:admit, name}, {pid, _tag}, state) do
    case Map.fetch(state.services, name) do
      {:ok, service} -> admit_service(service, pid, state)
      :error -> {:reply, :unknown, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, %{state | admitted: Map.delete(state.admitted, ref)}}
  end

  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = :gen_tcp.close(state.listen)
    _ = stop_connections(state.conns)
    _ = File.rm(state.path)
    :ok
  end

  @spec admit_service(GuestService.t(), pid(), map()) ::
          {:reply, {:ok, GuestService.t()} | :full, map()}
  defp admit_service(%GuestService{name: name, max_connections: max} = service, pid, state) do
    if Enum.count(state.admitted, fn {_ref, admitted} -> admitted == name end) < max do
      ref = Process.monitor(pid)
      {:reply, {:ok, service}, %{state | admitted: Map.put(state.admitted, ref, name)}}
    else
      {:reply, :full, state}
    end
  end

  @spec accept_loop(map(), pid(), {integer() | nil, non_neg_integer()}, boolean()) :: :ok
  defp accept_loop(%{listen: listen, conns: conns} = state, listener, window, failing?) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        {window, allowed?} = tick(window, System.monotonic_time(:second))

        _ =
          if allowed?,
            do: hand_off(socket, conns, listener, state.vm_id),
            else: :gen_tcp.close(socket)

        accept_loop(state, listener, window, false)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        :ok = report_accept_error(state.vm_id, reason, failing?)
        Process.sleep(Time.as_ms(@accept_backoff))
        accept_loop(state, listener, window, true)
    end
  end

  @spec report_accept_error(Hyper.Vm.Id.t(), term(), boolean()) :: :ok
  defp report_accept_error(_vm_id, _reason, true), do: :ok

  defp report_accept_error(vm_id, reason, false),
    do: Logger.warning("vm #{vm_id}: guest services: accept failing: #{inspect(reason)}")

  @spec tick({integer() | nil, non_neg_integer()}, integer()) ::
          {{integer(), non_neg_integer()}, boolean()}
  defp tick({second, count}, second), do: {{second, count + 1}, count < @accepts_per_second}
  defp tick(_window, second), do: {{second, 1}, true}

  @spec hand_off(:gen_tcp.socket(), pid(), pid(), Hyper.Vm.Id.t()) :: :ok
  defp hand_off(socket, conns, listener, vm_id) do
    with {:ok, pid} <- DynamicSupervisor.start_child(conns, {Connection, {listener, vm_id}}),
         :ok <- :gen_tcp.controlling_process(socket, pid) do
      Connection.serve(pid, socket)
    else
      _refused -> :gen_tcp.close(socket)
    end
  end

  @spec stop_connections(pid()) :: :ok
  defp stop_connections(conns) do
    DynamicSupervisor.stop(conns, :shutdown)
  catch
    :exit, _ -> :ok
  end
end
