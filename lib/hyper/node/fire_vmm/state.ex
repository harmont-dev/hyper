defmodule Hyper.Node.FireVMM.State do
  @moduledoc """
  `:gen_statem` controller for one microVM. Owns the firecracker daemon's
  lifecycle: launches it into the per-VM `DynamicSupervisor`, monitors it, and
  decides what happens when it dies.

      :booting --> :running <-> :paused --> :stopping
          ^            |
          +- :crashed <+   (daemon died unexpectedly; cold-boot or restore)

  This module's struct is the gen_statem *data*; the gen_statem *state* is the
  lifecycle atom above.
  """

  @behaviour :gen_statem

  alias Hyper.Node.FireVMM.State
  alias Hyper.Node.FireVMM.Boot
  alias Hyper.Node.FireVMM.Client

  @enforce_keys [:id, :socket_path, :source, :binary, :args]
  defstruct [:id, :socket_path, :source, :type, :binary, :args, :daemon, :daemon_ref, :run]

  @type t :: %State{
          id: String.t(),
          socket_path: Path.t(),
          source: Hyper.vm_source(),
          type: Hyper.Vm.Instance.t() | nil,
          binary: String.t(),
          args: [String.t()],
          daemon: pid() | nil,
          daemon_ref: reference() | nil,
          run: Hyper.Node.FireVMM.Boot.run() | nil
        }

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  def start_link(%{id: id} = opts), do: :gen_statem.start_link(via(id), __MODULE__, opts, [])

  @spec pause(String.t()) :: :ok
  def pause(id), do: :gen_statem.call(via(id), :pause)

  @spec resume(String.t()) :: :ok
  def resume(id), do: :gen_statem.call(via(id), :resume)

  @spec stop(String.t()) :: :ok
  def stop(id), do: :gen_statem.call(via(id), :stop)

  @impl :gen_statem
  def callback_mode, do: :state_functions

  @impl :gen_statem
  def init(%{id: id, socket_path: socket, source: source} = opts) do
    data = %State{
      id: id,
      socket_path: socket,
      source: source,
      type: Map.get(opts, :type),
      # FireVMM resolves these from the jailer command; defaults are a safety net.
      binary: Map.get(opts, :binary, "jailer"),
      args: Map.get(opts, :args, []),
      # Test seam: nil -> the real Client-backed closure is built at boot time.
      run: Map.get(opts, :run)
    }

    {:ok, :booting, data, [{:state_timeout, 0, :launch}]}
  end

  def booting(:state_timeout, :launch, %State{source: source, type: type} = data) do
    data = ensure_daemon(data)

    case Boot.boot(runner(data), source, type) do
      :ok ->
        {:next_state, :running, data}

      {:error, reason} ->
        # The daemon is up but unconfigured; tear the whole VM down and let the
        # supervisor's restart intensity backstop a persistently-bad spec.
        {:stop, {:shutdown, {:boot_failed, reason}}, data}
    end
  end

  def running({:call, from}, :pause, data) do
    case Boot.pause(runner(data)) do
      :ok -> {:next_state, :paused, data, [{:reply, from, :ok}]}
      {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def running({:call, from}, :stop, data),
    do: {:next_state, :stopping, data, [{:reply, from, :ok}]}

  def running(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data),
    do: {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}

  def paused({:call, from}, :resume, data) do
    case Boot.resume(runner(data)) do
      :ok -> {:next_state, :running, data, [{:reply, from, :ok}]}
      {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def paused(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data),
    do: {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}

  def crashed(:state_timeout, :recover, data),
    do: {:next_state, :booting, data, [{:state_timeout, 0, :launch}]}

  def stopping({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :stopping}}]}

  @impl :gen_statem
  # Graceful stop: take the daemon down with us. Crash: leave it running so the
  # restarted controller re-adopts it (see ensure_daemon/1).
  def terminate(reason, _state, data) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason), do: stop_daemon(data)
    :ok
  end

  # Re-adopt a surviving daemon after a controller restart, else launch fresh.
  defp ensure_daemon(%State{id: id} = data) do
    case DynamicSupervisor.which_children(daemon_sup(id)) do
      [{_, pid, _, _}] when is_pid(pid) -> monitor(data, pid)
      _ -> start_daemon(data)
    end
  end

  defp start_daemon(%State{id: id, binary: bin, args: args} = data) do
    # The jailer creates the chroot (and thus the socket's parent dir) itself, so
    # there's nothing to mkdir here. MuonTrap just supervises the OS process.
    spec =
      Supervisor.child_spec(
        {MuonTrap.Daemon, [bin, args, []]},
        # :temporary -> the state machine, not the supervisor, decides restarts.
        id: :firecracker,
        restart: :temporary
      )

    {:ok, pid} = DynamicSupervisor.start_child(daemon_sup(id), spec)
    monitor(data, pid)
  end

  defp stop_daemon(%State{daemon: nil}), do: :ok

  defp stop_daemon(%State{id: id, daemon: pid}),
    do: DynamicSupervisor.terminate_child(daemon_sup(id), pid)

  defp monitor(data, pid), do: %{data | daemon: pid, daemon_ref: Process.monitor(pid)}
  defp clear_daemon(data), do: %{data | daemon: nil, daemon_ref: nil}

  defp recover_after, do: 1_000

  # The API `run` closure for this VM: injected one (tests) or the real
  # Client-backed one, serialized through the per-VM Client GenServer.
  defp runner(%State{run: run}) when is_function(run, 1), do: run
  defp runner(%State{id: id}), do: &Client.run(Client.via(id), &1)

  defp daemon_sup(id), do: Hyper.Cluster.Routing.via({id, :daemon_sup})
  defp via(id), do: Hyper.Cluster.Routing.via({id, :state})
end
