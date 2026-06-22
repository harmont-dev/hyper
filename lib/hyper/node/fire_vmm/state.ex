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

  Uses `:handle_event_function` mode: each state's events live in a nested
  submodule (`Booting`, `AwaitingApi`, ...), and `handle_event/4` dispatches to
  them - except daemon death, which is one shared clause across every live
  state. Each boot step does one short thing and returns control to the
  gen_statem loop; the firecracker API structs are built by
  `Hyper.Node.FireVMM.BootSpec` and every call goes through the per-VM `Client`.

  The gen_statem *data* (this module's struct) holds the start `Opts` plus the
  runtime fields (the daemon and its monitor, the resolved boot spec, the
  readiness deadline); the gen_statem *state* is the lifecycle atom above.
  """

  @behaviour :gen_statem

  alias Hyper.Node.FireVMM.BootSpec
  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Node.FireVMM.State
  alias Hyper.Node.FireVMM.State.Daemon
  alias Unit.Time
  alias __MODULE__.{AwaitingApi, Booting, Configuring, Crashed, Paused, Running, Stopping}

  @enforce_keys [:opts]
  defstruct [:opts, :daemon, :daemon_ref, :spec, :boot_deadline]

  @type t :: %State{
          opts: Opts.t(),
          daemon: pid() | nil,
          daemon_ref: reference() | nil,
          spec: BootSpec.Cold.t() | nil,
          boot_deadline: integer() | nil
        }

  # Delay before a crashed VM tries to recover (cold boot / re-adopt).
  @recover_delay Time.s(1)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(%Opts{vm_id: id} = opts) do
    :gen_statem.start_link(via(id), __MODULE__, opts, [])
  end

  @spec pause(Hyper.Vm.id()) :: :ok
  def pause(id) do
    :gen_statem.call(via(id), :pause)
  end

  @spec resume(Hyper.Vm.id()) :: :ok
  def resume(id) do
    :gen_statem.call(via(id), :resume)
  end

  @spec stop(Hyper.Vm.id()) :: :ok
  def stop(id) do
    :gen_statem.call(via(id), :stop)
  end

  @impl :gen_statem
  def callback_mode do
    :handle_event_function
  end

  @impl :gen_statem
  def init(%Opts{} = opts) do
    {:ok, :booting, %State{opts: opts}, [{:state_timeout, 0, :launch}]}
  end

  @impl :gen_statem
  # Daemon death in any live state -> crashed, then recover. One clause for every
  # state instead of one per state; excluded while :stopping, where teardown is
  # already underway (and in :booting/:crashed `daemon_ref` is nil, so the ref
  # match can't fire there anyway).
  def handle_event(
        :info,
        {:DOWN, ref, :process, _pid, _reason},
        state,
        %State{daemon_ref: ref} = data
      )
      when state != :stopping do
    {:next_state, :crashed, %{data | daemon: nil, daemon_ref: nil},
     [{:state_timeout, Time.as_ms(@recover_delay), :recover}]}
  end

  def handle_event(type, content, state, data) do
    module =
      case state do
        :booting -> Booting
        :awaiting_api -> AwaitingApi
        :configuring -> Configuring
        :running -> Running
        :paused -> Paused
        :crashed -> Crashed
        :stopping -> Stopping
      end

    module.handle(type, content, data)
  end

  @impl :gen_statem
  # Graceful stop: take the daemon down with us. Crash: leave it running so the
  # restarted controller re-adopts it (re-adopted in Booting via Daemon.ensure/1).
  def terminate(reason, _state, %State{opts: %Opts{vm_id: id}, daemon: daemon}) do
    _ =
      if daemon && (reason in [:normal, :shutdown] or match?({:shutdown, _}, reason)) do
        Daemon.stop(id, daemon)
      end

    :ok
  end

  defp via(id) do
    Hyper.Cluster.Routing.via({id, :state})
  end

  defmodule Booting do
    @moduledoc false

    alias Hyper.Node.FireVMM.{BootSpec, Opts}
    alias Hyper.Node.FireVMM.State.Daemon
    alias Unit.Time

    # How long to wait for the daemon's API to come up.
    @ready_timeout Time.s(10)

    # Resolve the boot spec, launch (or re-adopt) the daemon and monitor it, then
    # start waiting for its API.
    def handle(:state_timeout, :launch, %{opts: %Opts{source: source, type: type} = opts} = data) do
      pid = Daemon.ensure(opts)
      spec = BootSpec.resolve(source, type)
      deadline = System.monotonic_time(:millisecond) + Time.as_ms(@ready_timeout)

      data = %{
        data
        | spec: spec,
          daemon: pid,
          daemon_ref: Process.monitor(pid),
          boot_deadline: deadline
      }

      {:next_state, :awaiting_api, data, [{:state_timeout, 0, :probe}]}
    end

    # A caller may stop (or try to pause/resume) before the launch timeout fires.
    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end

    def handle({:call, from}, event, _data) when event in [:pause, :resume] do
      {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
    end
  end

  defmodule AwaitingApi do
    @moduledoc false

    alias Hyper.Firecracker.Api.{InstanceInfo, Operations}
    alias Hyper.Node.FireVMM.{Client, Opts}
    alias Unit.Time

    # How often to probe the daemon's API while waiting for it.
    @probe_interval Time.ms(50)

    # Poll the daemon's API until it answers. A re-adopted daemon (controller
    # restarted, daemon survived) may already be running its guest ("Running" /
    # "Paused"); re-issuing pre-boot config would 400 and the stop-on-failure
    # path would kill it, so it skips straight to :running. A freshly-launched
    # daemon reports "Not started" -> configure it.
    def handle(:state_timeout, :probe, %{opts: %Opts{vm_id: id}} = data) do
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

    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end

    def handle({:call, from}, event, _data) when event in [:pause, :resume] do
      {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
    end
  end

  defmodule Configuring do
    @moduledoc false

    alias Hyper.Firecracker.Api.{InstanceActionInfo, Operations}
    alias Hyper.Node.FireVMM.{BootSpec, Client, Opts}

    # Issue the pre-boot config and start the guest, then run.
    def handle(:state_timeout, :configure, %{opts: %Opts{vm_id: id}, spec: spec} = data) do
      case apply_spec(id, spec) do
        :ok -> {:next_state, :running, data}
        {:error, reason} -> {:stop, {:shutdown, {:boot_failed, reason}}, data}
      end
    end

    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end

    def handle({:call, from}, event, _data) when event in [:pause, :resume] do
      {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
    end

    # Cold boot, issued through the Client and aborting at the first error:
    # machine-config -> boot-source -> each drive -> each NIC -> InstanceStart.
    @spec apply_spec(Hyper.Vm.id(), BootSpec.Cold.t()) :: :ok | {:error, term()}
    defp apply_spec(id, %BootSpec.Cold{} = cold) do
      via = Client.via(id)

      ops =
        [
          fn opts -> Operations.put_machine_configuration(cold.machine_config, opts) end,
          fn opts -> Operations.put_guest_boot_source(cold.boot_source, opts) end
        ] ++
          Enum.map(cold.drives, fn drive ->
            fn opts -> Operations.put_guest_drive_by_id(drive.drive_id, drive, opts) end
          end) ++
          Enum.map(cold.network_interfaces, fn nic ->
            fn opts -> Operations.put_guest_network_interface_by_id(nic.iface_id, nic, opts) end
          end) ++
          [
            fn opts ->
              Operations.create_sync_action(
                %InstanceActionInfo{action_type: "InstanceStart"},
                opts
              )
            end
          ]

      Enum.reduce_while(ops, :ok, fn op, :ok ->
        case Client.run(via, op) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  defmodule Running do
    @moduledoc false

    alias Hyper.Firecracker.Api.{Operations, Vm}
    alias Hyper.Node.FireVMM.{Client, Opts}

    def handle({:call, from}, :pause, %{opts: %Opts{vm_id: id}} = data) do
      case Client.run(Client.via(id), fn opts ->
             Operations.patch_vm(%Vm{state: "Paused"}, opts)
           end) do
        :ok -> {:next_state, :paused, data, [{:reply, from, :ok}]}
        {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
      end
    end

    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end

    # Already running: resume is a no-op.
    def handle({:call, from}, :resume, _data) do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end
  end

  defmodule Paused do
    @moduledoc false

    alias Hyper.Firecracker.Api.{Operations, Vm}
    alias Hyper.Node.FireVMM.{Client, Opts}

    def handle({:call, from}, :resume, %{opts: %Opts{vm_id: id}} = data) do
      case Client.run(Client.via(id), fn opts ->
             Operations.patch_vm(%Vm{state: "Resumed"}, opts)
           end) do
        :ok -> {:next_state, :running, data, [{:reply, from, :ok}]}
        {:error, _} = err -> {:keep_state_and_data, [{:reply, from, err}]}
      end
    end

    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end

    # Already paused: pause is a no-op.
    def handle({:call, from}, :pause, _data) do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end
  end

  defmodule Crashed do
    @moduledoc false

    def handle(:state_timeout, :recover, data) do
      {:next_state, :booting, data, [{:state_timeout, 0, :launch}]}
    end

    # A call can arrive before the recover timeout fires.
    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end

    def handle({:call, from}, event, _data) when event in [:pause, :resume] do
      {:keep_state_and_data, [{:reply, from, {:error, :not_running}}]}
    end
  end

  defmodule Stopping do
    @moduledoc false

    # Daemon death during teardown is expected; ignore it (we're already stopping).
    def handle(:info, {:DOWN, _ref, :process, _pid, _reason}, _data) do
      :keep_state_and_data
    end

    def handle({:call, from}, _event, _data) do
      {:keep_state_and_data, [{:reply, from, {:error, :stopping}}]}
    end
  end
end
