defmodule Hyper.Node.FireVMM.State do
  @moduledoc """
  `:gen_statem` controller for one microVM. It drives the boot protocol against a
  daemon whose lifecycle is owned by the supervisor (`Hyper.Node.FireVMM.Core`,
  `:one_for_all`): the controller does not launch, monitor, or kill the daemon -
  if firecracker dies, `Core` restarts the daemon and this controller together,
  and `init` simply cold-boots again.

      :awaiting_api --> :staging --> :configuring --> :running --> :stopping

  States:

    * `:awaiting_api` - poll the (already-launched) daemon's API socket until it
                        answers, or fail the boot if the readiness deadline lapses.
    * `:staging`      - stage the kernel + rootfs device into the jail chroot and
                        rewrite the spec to in-jail paths.
    * `:configuring`  - push machine-config, boot-source, drives, NICs, then
                        `InstanceStart`.
    * `:running`      - guest is live; handles `stop`.
    * `:stopping`     - teardown requested in-band; reject further calls.

  Uses `:handle_event_function` mode: each state's events live in a nested
  submodule (`AwaitingApi`, `Staging`, ...) that `handle_event/4` dispatches to.
  Each step does one short thing and returns to the gen_statem loop; API structs
  come from `Hyper.Node.FireVMM.BootSpec` and every call goes through the per-VM
  `Client`.

  The gen_statem *data* (this struct) holds the start `Opts`, the resolved boot
  spec, and the readiness deadline; the *state* is the lifecycle atom above.
  """

  @behaviour :gen_statem

  alias Hyper.Node.FireVMM.BootSpec
  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Node.FireVMM.State
  alias Unit.Time

  alias __MODULE__.{
    AwaitingApi,
    Configuring,
    Running,
    Staging,
    Stopping
  }

  @enforce_keys [:opts]
  defstruct [:opts, :spec, :boot_deadline]

  @type t :: %State{
          opts: Opts.t(),
          spec: BootSpec.Cold.t() | nil,
          boot_deadline: integer() | nil
        }

  # How long to wait for the daemon's API to come up before failing the boot.
  @ready_timeout Time.s(10)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(%Opts{vm_id: id} = opts) do
    :gen_statem.start_link(via(id), __MODULE__, opts, [])
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
  # The daemon is already (being) started by `Core` as our sibling. Resolve the
  # boot spec, set the readiness deadline, and start probing the API.
  def init(%Opts{source: source, type: type} = opts) do
    spec = BootSpec.resolve(source, type)
    deadline = System.monotonic_time(:millisecond) + Time.as_ms(@ready_timeout)
    data = %State{opts: opts, spec: spec, boot_deadline: deadline}

    {:ok, :awaiting_api, data, [{:state_timeout, 0, :probe}]}
  end

  @impl :gen_statem
  def handle_event(type, content, state, data) do
    module =
      case state do
        :awaiting_api -> AwaitingApi
        :staging -> Staging
        :configuring -> Configuring
        :running -> Running
        :stopping -> Stopping
      end

    module.handle(type, content, data)
  end

  defp via(id) do
    Hyper.Cluster.Routing.via({id, :state})
  end

  defmodule AwaitingApi do
    @moduledoc """
    Poll the (already-launched) daemon's API socket until it answers, then advance
    to `:staging`. If the readiness deadline lapses before the API responds, the
    boot fails.
    """

    alias Hyper.Firecracker.Api.{InstanceInfo, Operations}
    alias Hyper.Node.FireVMM.{Client, Opts}
    alias Unit.Time

    # How often to probe the daemon's API while waiting for it.
    @probe_interval Time.ms(50)

    # Poll the daemon's API until it answers, then stage + configure. Give up if
    # the readiness deadline passes first.
    def handle(:state_timeout, :probe, %{opts: %Opts{vm_id: id}} = data) do
      case Client.run(Client.via(id), &Operations.describe_instance/1) do
        {:ok, %InstanceInfo{}} ->
          {:next_state, :staging, data, [{:state_timeout, 0, :stage}]}

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
  end

  defmodule Staging do
    @moduledoc """
    Stage the kernel + rootfs device into the jail chroot and rewrite the boot
    spec to the in-jail paths (`Hyper.Node.FireVMM.ChrootJail.stage/4`), then
    advance to `:configuring`. Staging failure fails the boot.
    """

    alias Hyper.Node.FireVMM.{ChrootJail, Opts}

    # Stage the kernel + rootfs device into the chroot, rewriting the boot spec to
    # the in-jail paths, then proceed to configuring.
    def handle(
          :state_timeout,
          :stage,
          %{opts: %Opts{vm_id: id, uid: uid, gid: gid}, spec: spec} = data
        ) do
      case ChrootJail.stage(id, uid, gid, spec) do
        {:ok, spec} ->
          {:next_state, :configuring, %{data | spec: spec}, [{:state_timeout, 0, :configure}]}

        {:error, reason} ->
          {:stop, {:shutdown, {:boot_failed, {:staging, reason}}}, data}
      end
    end

    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end
  end

  defmodule Configuring do
    @moduledoc """
    Push the cold-boot config to firecracker through the per-VM `Client`
    (machine-config -> boot-source -> drives -> NICs -> `InstanceStart`), aborting
    at the first error, then enter `:running`. Any step failing fails the boot.
    """

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
    @moduledoc "The guest is live. Handles `stop` (-> `:stopping`)."

    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end
  end

  defmodule Stopping do
    @moduledoc """
    Teardown was requested in-band (`stop/1`). The actual teardown is
    supervisor-driven (the node terminates the VM tree); here we just reject any
    further calls with `{:error, :stopping}`.
    """

    def handle({:call, from}, _event, _data) do
      {:keep_state_and_data, [{:reply, from, {:error, :stopping}}]}
    end
  end
end
