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
  pre-boot config + `InstanceStart`. The firecracker API structs are built by
  `Hyper.Node.FireVMM.BootSpec`; every call goes through the per-VM `Client`.

  The gen_statem *data* (this module's struct) holds the start `Opts` plus the
  runtime fields (the daemon and its monitor, the resolved boot spec, the
  readiness deadline); the gen_statem *state* is the lifecycle atom above.
  """

  @behaviour :gen_statem

  alias Hyper.Firecracker.Api.{InstanceActionInfo, InstanceInfo, Operations, Vm}
  alias Hyper.Node.FireVMM.BootSpec
  alias Hyper.Node.FireVMM.Client
  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Node.FireVMM.State
  alias Hyper.Node.FireVMM.State.Daemon
  alias Unit.Time

  @enforce_keys [:opts]
  defstruct [:opts, :daemon, :daemon_ref, :spec, :boot_deadline]

  @type t :: %State{
          opts: Opts.t(),
          daemon: pid() | nil,
          daemon_ref: reference() | nil,
          spec: BootSpec.Cold.t() | nil,
          boot_deadline: integer() | nil
        }

  # How long to wait for the daemon's API to come up, and how often to probe it.
  @ready_timeout Time.s(10)
  @probe_interval Time.ms(50)
  # Delay before a crashed VM tries to recover (cold boot / re-adopt).
  @recover_delay Time.s(1)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(%Opts{vm_id: id} = opts) do
    :gen_statem.start_link(via(id), __MODULE__, opts, [])
  end

  @spec pause(String.t()) :: :ok
  def pause(id) do
    :gen_statem.call(via(id), :pause)
  end

  @spec resume(String.t()) :: :ok
  def resume(id) do
    :gen_statem.call(via(id), :resume)
  end

  @spec stop(String.t()) :: :ok
  def stop(id) do
    :gen_statem.call(via(id), :stop)
  end

  @impl :gen_statem
  def callback_mode do
    :state_functions
  end

  @impl :gen_statem
  def init(%Opts{} = opts) do
    {:ok, :booting, %State{opts: opts}, [{:state_timeout, 0, :launch}]}
  end

  # Resolve the boot spec, then launch (or re-adopt) the daemon and start waiting
  # for its API.
  def booting(:state_timeout, :launch, %State{opts: %Opts{source: source, type: type}} = data) do
    data = ensure_daemon(%{data | spec: BootSpec.resolve(source, type)})
    deadline = System.monotonic_time(:millisecond) + Time.as_ms(@ready_timeout)
    {:next_state, :awaiting_api, %{data | boot_deadline: deadline}, [{:state_timeout, 0, :probe}]}
  end

  # A caller may stop (or try to pause/resume) before the launch timeout fires;
  # handle it here so an early call can't crash the controller.
  def booting({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def booting({:call, from}, event, _data) when event in [:pause, :resume] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  # Poll the daemon's API until it answers. A re-adopted daemon (controller
  # restarted, daemon survived) may already be running its guest ("Running" /
  # "Paused"); re-issuing pre-boot config would 400 and the stop-on-failure path
  # would kill it, so it skips straight to :running. A freshly-launched daemon
  # reports "Not started" -> configure it.
  def awaiting_api(:state_timeout, :probe, %State{opts: %Opts{vm_id: id}} = data) do
    case Client.run(Client.via(id), &Operations.describe_instance/1) do
      {:ok, %InstanceInfo{state: state}} when state in ["Running", "Paused"] ->
        {:next_state, :running, data}

      {:ok, %InstanceInfo{}} ->
        {:next_state, :configuring, data, [{:state_timeout, 0, :configure}]}

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= data.boot_deadline do
          {:stop, {:shutdown, {:boot_failed, :daemon_unready}}, data}
        else
          {:keep_state_and_data, [{:state_timeout, Time.as_ms(@probe_interval), :probe}]}
        end
    end
  end

  def awaiting_api(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data) do
    {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}
  end

  def awaiting_api({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def awaiting_api({:call, from}, event, _data) when event in [:pause, :resume] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  # Issue the pre-boot config and start the guest. One short blocking step of a
  # few fast calls; aborts and tears down on the first error.
  def configuring(:state_timeout, :configure, %State{opts: %Opts{vm_id: id}, spec: spec} = data) do
    case apply_spec(id, spec) do
      :ok -> {:next_state, :running, data}
      {:error, reason} -> {:stop, {:shutdown, {:boot_failed, reason}}, data}
    end
  end

  def configuring(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data) do
    {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}
  end

  def configuring({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def configuring({:call, from}, event, _data) when event in [:pause, :resume] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def running({:call, from}, :pause, %State{opts: %Opts{vm_id: id}} = data) do
    case set_vm_state(Client.via(id), "Paused") do
      :ok -> {:next_state, :paused, data, [{:reply, from, :ok}]}
      {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def running({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def running(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data) do
    {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}
  end

  def paused({:call, from}, :resume, %State{opts: %Opts{vm_id: id}} = data) do
    case set_vm_state(Client.via(id), "Resumed") do
      :ok -> {:next_state, :running, data, [{:reply, from, :ok}]}
      {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
    end
  end

  def paused(:info, {:DOWN, ref, :process, _pid, _reason}, %State{daemon_ref: ref} = data) do
    {:next_state, :crashed, clear_daemon(data), [{:state_timeout, recover_after(), :recover}]}
  end

  def crashed(:state_timeout, :recover, data) do
    {:next_state, :booting, data, [{:state_timeout, 0, :launch}]}
  end

  # Same as :booting: a call can arrive before the recover timeout fires.
  def crashed({:call, from}, :stop, data) do
    {:next_state, :stopping, data, [{:reply, from, :ok}]}
  end

  def crashed({:call, from}, event, _data) when event in [:pause, :resume] do
    {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
  end

  def stopping({:call, from}, _event, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, :stopping}}]}
  end

  @impl :gen_statem
  # Graceful stop: take the daemon down with us. Crash: leave it running so the
  # restarted controller re-adopts it (see ensure_daemon/1).
  def terminate(reason, _state, %State{opts: %Opts{vm_id: id}, daemon: daemon}) do
    if daemon && (reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)) do
      Daemon.stop(id, daemon)
    end

    :ok
  end

  # --- boot protocol -------------------------------------------------------

  # Cold boot: machine-config -> boot-source -> drives -> NICs -> InstanceStart.
  # Aborts at the first error, returned verbatim.
  @spec apply_spec(Hyper.Vm.id(), BootSpec.Cold.t()) :: :ok | {:error, term()}
  defp apply_spec(id, %BootSpec.Cold{} = cold) do
    via = Client.via(id)

    with :ok <-
           Client.run(via, fn opts ->
             Operations.put_machine_configuration(cold.machine_config, opts)
           end),
         :ok <-
           Client.run(via, fn opts -> Operations.put_guest_boot_source(cold.boot_source, opts) end),
         :ok <- put_each(via, cold.drives, &drive_put/2),
         :ok <- put_each(via, cold.network_interfaces, &nic_put/2) do
      Client.run(via, fn opts ->
        Operations.create_sync_action(%InstanceActionInfo{action_type: "InstanceStart"}, opts)
      end)
    end
  end

  # Issue `put_fun` for each item, halting at the first error.
  @spec put_each(GenServer.server(), [item], (GenServer.server(), item ->
                                                :ok | {:error, term()})) ::
          :ok | {:error, term()}
        when item: var
  defp put_each(via, items, put_fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case put_fun.(via, item) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp drive_put(via, drive) do
    Client.run(via, fn opts -> Operations.put_guest_drive_by_id(drive.drive_id, drive, opts) end)
  end

  defp nic_put(via, nic) do
    Client.run(via, fn opts ->
      Operations.put_guest_network_interface_by_id(nic.iface_id, nic, opts)
    end)
  end

  defp set_vm_state(via, state) do
    Client.run(via, fn opts -> Operations.patch_vm(%Vm{state: state}, opts) end)
  end

  # --- daemon lifecycle ----------------------------------------------------

  # Launch (or re-adopt) the daemon via `Daemon`, then monitor it ourselves.
  defp ensure_daemon(%State{opts: opts} = data) do
    monitor(data, Daemon.ensure(opts))
  end

  defp monitor(data, pid) do
    %{data | daemon: pid, daemon_ref: Process.monitor(pid)}
  end

  defp clear_daemon(data) do
    %{data | daemon: nil, daemon_ref: nil}
  end

  defp recover_after do
    Time.as_ms(@recover_delay)
  end

  defp via(id) do
    Hyper.Cluster.Routing.via({id, :state})
  end
end
