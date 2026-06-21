defmodule Hyper.Node.FireVMM.State do
  @moduledoc """
  `:gen_statem` controller for one microVM. Owns the firecracker daemon's
  lifecycle: launches it into the per-VM `DynamicSupervisor`, monitors it, and
  decides what happens when it dies. The boot protocol (waiting for the API,
  then configuring + starting the guest) is modelled as states rather than a
  blocking call, so the controller stays responsive to daemon death and `stop`
  while a VM is coming up.

      :booting --> :awaiting_api --> :configuring --> :running <-> :paused --> :stopping
          ^             |                  |
          +- :crashed <-+------------------+   (daemon died / never came up; recover)

  Each boot step does one short thing and returns control to the gen_statem
  loop: `:awaiting_api` polls `describe_instance` on a `:state_timeout` cadence
  until the daemon answers (or a deadline lapses); `:configuring` issues the
  pre-boot config + `InstanceStart` (cold) or `load_snapshot` (restore). The
  firecracker API structs are built by `Hyper.Node.FireVMM.BootSpec`; every call
  goes through `runner/1` - the injected test closure or the per-VM `Client`.

  This module's struct is the gen_statem *data*; the gen_statem *state* is the
  lifecycle atom above.
  """

  @behaviour :gen_statem

  alias Hyper.Firecracker.Api.{InstanceActionInfo, Operations, Vm}
  alias Hyper.Node.FireVMM.BootSpec
  alias Hyper.Node.FireVMM.Client
  alias Hyper.Node.FireVMM.State

  @typedoc "A closure that runs one generated API operation, returning its result."
  @type run :: ((keyword() -> term()) -> term())

  @enforce_keys [:id, :socket_path, :source, :binary, :args]
  defstruct [
    :id,
    :socket_path,
    :source,
    :type,
    :binary,
    :args,
    :daemon,
    :daemon_ref,
    :run,
    :spec,
    :boot_deadline
  ]

  @type t :: %State{
          id: String.t(),
          socket_path: Path.t(),
          source: Hyper.vm_source(),
          type: Hyper.Vm.Instance.t() | nil,
          binary: String.t(),
          args: [String.t()],
          daemon: pid() | nil,
          daemon_ref: reference() | nil,
          run: run() | nil,
          spec: BootSpec.Cold.t() | BootSpec.Restore.t() | nil,
          boot_deadline: integer() | nil
        }

  # How long to wait for the daemon's API to come up, and how often to probe it.
  @ready_timeout_ms 10_000
  @probe_interval_ms 50

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

  # Resolve the boot spec first (a bad source must not leave a daemon running),
  # then launch (or re-adopt) the daemon and start waiting for its API.
  def booting(:state_timeout, :launch, %State{source: source, type: type} = data) do
    case BootSpec.resolve(source, type) do
      {:ok, spec} ->
        data = ensure_daemon(%{data | spec: spec})
        deadline = now() + @ready_timeout_ms

        {:next_state, :awaiting_api, %{data | boot_deadline: deadline},
         [{:state_timeout, 0, :probe}]}

      {:error, reason} ->
        {:stop, {:shutdown, {:boot_failed, reason}}, data}
    end
  end

  # A caller may stop (or try to pause/resume) before the launch timeout fires;
  # handle it here so an early call can't crash the controller.
  def booting({:call, from}, :stop, data),
    do: {:next_state, :stopping, data, [{:reply, from, :ok}]}

  def booting({:call, from}, event, _data) when event in [:pause, :resume],
    do: {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}

  # Poll the daemon's API until it answers. A re-adopted daemon (controller
  # restarted, daemon survived) may already be running its guest; re-issuing
  # pre-boot config would 400 and the stop-on-failure path would kill it, so an
  # already-started guest skips straight to :running. A freshly-launched daemon
  # reports "Not started" -> configure it.
  def awaiting_api(:state_timeout, :probe, data) do
    case runner(data).(&Operations.describe_instance/1) do
      {:ok, info} ->
        if instance_started?(info),
          do: {:next_state, :running, data},
          else: {:next_state, :configuring, data, [{:state_timeout, 0, :configure}]}

      {:error, _reason} ->
        if now() >= data.boot_deadline do
          {:stop, {:shutdown, {:boot_failed, :daemon_unready}}, data}
        else
          {:keep_state_and_data, [{:state_timeout, @probe_interval_ms, :probe}]}
        end
    end
  end

  def awaiting_api(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data),
    do: {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}

  def awaiting_api({:call, from}, :stop, data),
    do: {:next_state, :stopping, data, [{:reply, from, :ok}]}

  def awaiting_api({:call, from}, event, _data) when event in [:pause, :resume],
    do: {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}

  # Issue the pre-boot config + start (cold) or restore (snapshot). One short
  # blocking step of a few fast calls; aborts and tears down on the first error.
  def configuring(:state_timeout, :configure, %State{spec: spec} = data) do
    case apply_spec(runner(data), spec) do
      :ok -> {:next_state, :running, data}
      {:error, reason} -> {:stop, {:shutdown, {:boot_failed, reason}}, data}
    end
  end

  def configuring(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data),
    do: {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}

  def configuring({:call, from}, :stop, data),
    do: {:next_state, :stopping, data, [{:reply, from, :ok}]}

  def configuring({:call, from}, event, _data) when event in [:pause, :resume],
    do: {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}

  def running({:call, from}, :pause, data) do
    case set_vm_state(runner(data), "Paused") do
      :ok -> {:next_state, :paused, data, [{:reply, from, :ok}]}
      {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def running({:call, from}, :stop, data),
    do: {:next_state, :stopping, data, [{:reply, from, :ok}]}

  def running(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data),
    do: {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}

  def paused({:call, from}, :resume, data) do
    case set_vm_state(runner(data), "Resumed") do
      :ok -> {:next_state, :running, data, [{:reply, from, :ok}]}
      {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def paused(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data),
    do: {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}

  def crashed(:state_timeout, :recover, data),
    do: {:next_state, :booting, data, [{:state_timeout, 0, :launch}]}

  # Same as :booting: a call can arrive before the recover timeout fires.
  def crashed({:call, from}, :stop, data),
    do: {:next_state, :stopping, data, [{:reply, from, :ok}]}

  def crashed({:call, from}, event, _data) when event in [:pause, :resume],
    do: {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}

  def stopping({:call, from}, _event, _data),
    do: {:keep_state_and_data, [{:reply, from, {:error, :stopping}}]}

  @impl :gen_statem
  # Graceful stop: take the daemon down with us. Crash: leave it running so the
  # restarted controller re-adopts it (see ensure_daemon/1).
  def terminate(reason, _state, data) do
    if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason), do: stop_daemon(data)
    :ok
  end

  # --- boot protocol -------------------------------------------------------

  # Cold boot: machine-config -> boot-source -> drives -> NICs -> InstanceStart.
  # Restore: load the snapshot (resume). Aborts at the first error, returned
  # verbatim.
  @spec apply_spec(run(), BootSpec.Cold.t() | BootSpec.Restore.t()) :: :ok | {:error, term()}
  defp apply_spec(run, %BootSpec.Cold{} = cold) do
    with :ok <-
           run.(fn opts -> Operations.put_machine_configuration(cold.machine_config, opts) end),
         :ok <- run.(fn opts -> Operations.put_guest_boot_source(cold.boot_source, opts) end),
         :ok <- put_each(run, cold.drives, &drive_put/2),
         :ok <- put_each(run, cold.network_interfaces, &nic_put/2) do
      run.(fn opts ->
        Operations.create_sync_action(%InstanceActionInfo{action_type: "InstanceStart"}, opts)
      end)
    end
  end

  defp apply_spec(run, %BootSpec.Restore{params: params}) do
    run.(fn opts -> Operations.load_snapshot(params, opts) end)
  end

  @spec instance_started?(map()) :: boolean()
  defp instance_started?(%{state: state}) when state in ["Running", "Paused"], do: true
  defp instance_started?(_), do: false

  # Issue `put_fun` for each item, halting at the first error.
  @spec put_each(run(), [item], (run(), item -> :ok | {:error, term()})) :: :ok | {:error, term()}
        when item: var
  defp put_each(run, items, put_fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case put_fun.(run, item) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp drive_put(run, drive),
    do: run.(fn opts -> Operations.put_guest_drive_by_id(drive.drive_id, drive, opts) end)

  defp nic_put(run, nic),
    do: run.(fn opts -> Operations.put_guest_network_interface_by_id(nic.iface_id, nic, opts) end)

  defp set_vm_state(run, state),
    do: run.(fn opts -> Operations.patch_vm(%Vm{state: state}, opts) end)

  # The API `run` closure for this VM: injected one (tests) or the real
  # Client-backed one, serialized through the per-VM Client GenServer.
  defp runner(%State{run: run}) when is_function(run, 1), do: run
  defp runner(%State{id: id}), do: &Client.run(Client.via(id), &1)

  # --- daemon lifecycle ----------------------------------------------------

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
  defp now, do: System.monotonic_time(:millisecond)

  defp daemon_sup(id), do: Hyper.Cluster.Routing.via({id, :daemon_sup})
  defp via(id), do: Hyper.Cluster.Routing.via({id, :state})
end
