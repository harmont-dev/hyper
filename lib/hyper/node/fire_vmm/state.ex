defmodule Hyper.Node.FireVMM.State do
  @moduledoc """
  `:gen_statem` controller for one microVM. It drives the boot protocol against a
  daemon whose lifecycle is owned by the supervisor (`Hyper.Node.FireVMM.Core`,
  `:one_for_all`): the controller does not launch, monitor, or kill the daemon -
  if firecracker dies, `Core` restarts the daemon and this controller together,
  and `init` simply cold-boots again.

      :awaiting_api --> :configuring --> :running --> :stopping

  States:

    * `:awaiting_api` - poll the (already-launched) daemon's API socket until it
                        answers, or fail the boot if the readiness deadline lapses.
    * `:configuring`  - stage the kernel + rootfs device into the jail chroot
                        (rewriting the spec to in-jail paths), then push
                        machine-config, boot-source, drives, NICs, and
                        `InstanceStart`.
    * `:running`      - guest is live; handles `stop`.
    * `:stopping`     - teardown requested in-band; reject further calls.

  The gen_statem *data* (this struct) holds the start `Opts`, the resolved boot
  spec, and the readiness deadline; the *state* is the lifecycle atom above.
  """

  @behaviour :gen_statem

  alias Hyper.Node.FireVMM.BootSpec
  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Node.FireVMM.State
  alias Hyper.Node.Img.Mutable
  alias Unit.Time

  alias __MODULE__.{
    AwaitingApi,
    Configuring,
    Running,
    Stopping
  }

  @enforce_keys [:opts]
  defstruct [:opts, :spec, :boot_deadline, api_granted: false]

  @type t :: %State{
          opts: Opts.t(),
          spec: BootSpec.Cold.t() | nil,
          boot_deadline: integer() | nil,
          api_granted: boolean()
        }

  # How long to wait for the daemon's API to come up before failing the boot.
  @ready_timeout Time.s(5)

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end

  # Started unnamed; the controller self-registers under `{id, :state}` from
  # `init` (see `Hyper.Cluster.Routing.register_self/1`). `stop/1` still resolves
  # it cluster-wide through `via/1`.
  def start_link(%Opts{} = opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @spec stop(Hyper.Vm.Id.t()) :: :ok
  def stop(id) do
    :gen_statem.call(via(id), :stop)
  end

  @impl :gen_statem
  def callback_mode do
    :handle_event_function
  end

  @impl :gen_statem
  # The daemon is already (being) started by `Core` as our sibling. Read the root
  # device off the per-VM mutable layer, resolve the boot spec, set the readiness
  # deadline, and start probing the API.
  def init(
        %Opts{vm_id: id, mutable: mutable, kernel: kernel, boot_args: boot_args, type: type} =
          opts
      ) do
    case Hyper.Cluster.Routing.register_self({id, :state}) do
      :ok ->
        spec = BootSpec.resolve(boot_source(kernel, Mutable.blk_path(mutable), boot_args), type)
        deadline = System.monotonic_time(:millisecond) + Time.as_ms(@ready_timeout)
        data = %State{opts: opts, spec: spec, boot_deadline: deadline}

        {:ok, :awaiting_api, data, [{:state_timeout, 0, :probe}]}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  # Assemble the `Hyper.Vm.source()` BootSpec expects from the resolved kernel +
  # device. `boot_args` is omitted when nil so BootSpec applies its default.
  @spec boot_source(Path.t(), Path.t(), String.t() | nil) :: Hyper.Vm.source()
  defp boot_source(kernel, dev, nil),
    do: %{kernel_image_path: kernel, root_drive_path: dev}

  defp boot_source(kernel, dev, boot_args),
    do: %{kernel_image_path: kernel, root_drive_path: dev, boot_args: boot_args}

  @impl :gen_statem
  def handle_event(type, content, state, data) do
    module =
      case state do
        :awaiting_api -> AwaitingApi
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
    @moduledoc "Poll the (already-launched) daemon's API socket, then advance to `:configuring`."

    alias Hyper.Firecracker.Api.{InstanceInfo, Operations}
    alias Hyper.Node.FireVMM.{Client, Jailer, Opts}
    alias Hyper.SuidHelper.ChrootJail
    alias Unit.Time

    require Logger

    # How often to probe the daemon's API while waiting for it.
    @probe_interval Time.ms(50)

    # Hand the jailed API socket to the node user, then poll the daemon's API
    # until it answers and advance to `:configuring`. Give up if the readiness
    # deadline passes first. The grant must happen before the probe: firecracker
    # creates the socket owned by the per-VM uid, so the unprivileged controller
    # gets EACCES on connect until the helper chowns it to us.
    def handle(:state_timeout, :probe, %{opts: %Opts{vm_id: id}} = data) do
      case ensure_api_granted(id, data) do
        {:cont, data} ->
          case Client.run(Client.via(id), &Operations.describe_instance/1) do
            {:ok, %InstanceInfo{}} ->
              {:next_state, :configuring, data, [{:state_timeout, 0, :configure}]}

            {:error, reason} ->
              keep_probing(id, data, reason)
          end

        {:wait, data, reason} ->
          keep_probing(id, data, reason)
      end
    end

    def handle({:call, from}, :stop, data) do
      {:next_state, :stopping, data, [{:reply, from, :ok}]}
    end

    # Ensure the jailed API socket has been handed to the node user. Idempotent
    # once granted (we record it in `data` so we ask the helper only once).
    # `:socket_pending` means firecracker has not created the socket yet, so we
    # keep waiting; a hard error is logged but also tolerated until the deadline
    # (the probe that follows would fail with EACCES anyway and drive the stop).
    @spec ensure_api_granted(Hyper.Vm.Id.t(), State.t()) ::
            {:cont, State.t()} | {:wait, State.t(), term()}
    defp ensure_api_granted(_id, %{api_granted: true} = data), do: {:cont, data}

    defp ensure_api_granted(id, data) do
      case ChrootJail.grant_api(Jailer.host_socket(id)) do
        :ok ->
          {:cont, %{data | api_granted: true}}

        {:error, :socket_pending} ->
          {:wait, data, :socket_pending}

        {:error, reason} ->
          Logger.warning("vm #{id}: grant-api failed: #{inspect(reason)}")
          {:wait, data, {:grant_api, reason}}
      end
    end

    # Keep waiting for readiness, re-arming the probe timer, unless the deadline
    # has lapsed - then fail the boot, surfacing `reason` rather than swallowing
    # it into a bare `:daemon_unready`. A persistent failure here points at the
    # host->jail socket (path or, more often, the grant/permission step above).
    @spec keep_probing(Hyper.Vm.Id.t(), State.t(), term()) ::
            {:keep_state, State.t(), list()} | {:stop, term(), State.t()}
    defp keep_probing(id, data, reason) do
      if System.monotonic_time(:millisecond) >= data.boot_deadline do
        Logger.warning(
          "vm #{id}: firecracker API not reachable before deadline; " <>
            "last probe error: #{inspect(reason)}"
        )

        {:stop, {:shutdown, {:boot_failed, {:daemon_unready, reason}}}, data}
      else
        {:keep_state, data, [{:state_timeout, Time.as_ms(@probe_interval), :probe}]}
      end
    end
  end

  defmodule Configuring do
    @moduledoc "Stage the kernel + rootfs device into the jail chroot. Enter `:running` after."

    use OpenTelemetryDecorator

    alias Hyper.Firecracker.Api.{InstanceActionInfo, Operations}
    alias Hyper.Node.FireVMM.{BootSpec, ChrootJail, Client, Opts}

    require Logger

    # Stage boot artifacts into the chroot, then issue the pre-boot config and
    # start the guest. Both failure paths end the boot via a supervisor restart,
    # so log the reason here - otherwise it vanishes into the `:one_for_all`
    # cycle and the VM just appears to relaunch for no visible cause.
    def handle(
          :state_timeout,
          :configure,
          %{opts: %Opts{vm_id: id, uid: uid, gid: gid}, spec: spec} = data
        ) do
      case ChrootJail.stage(id, uid, gid, spec) do
        {:ok, jailed_spec} ->
          case apply_spec(id, jailed_spec) do
            :ok ->
              Logger.info("vm #{id}: configured, guest starting")
              {:next_state, :running, data}

            {:error, reason} ->
              Logger.error("vm #{id}: boot failed applying config: #{inspect(reason)}")
              {:stop, {:shutdown, {:boot_failed, reason}}, data}
          end

        {:error, reason} ->
          Logger.error("vm #{id}: boot failed staging jail: #{inspect(reason)}")
          {:stop, {:shutdown, {:boot_failed, {:staging, reason}}}, data}
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
    @spec apply_spec(Hyper.Vm.Id.t(), BootSpec.Cold.t()) :: :ok | {:error, term()}
    @decorate with_span("Hyper.Node.FireVMM.State.Configuring.apply_spec", include: [:id])
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
    Teardown was requested in-band.

    Actual tear-down is handled by the parent supervisor.
    """

    def handle({:call, from}, _event, _data) do
      {:keep_state_and_data, [{:reply, from, {:error, :stopping}}]}
    end
  end
end
