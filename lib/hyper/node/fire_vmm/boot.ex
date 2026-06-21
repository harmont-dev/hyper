defmodule Hyper.Node.FireVMM.Boot do
  @moduledoc """
  Drives a launched Firecracker daemon from "process alive" to "guest running"
  by issuing its REST API in order. Every call goes through an injected `run`
  closure (`((keyword -> result) -> result)`); in production that closure is
  `&Hyper.Node.FireVMM.Client.run(Client.via(id), &1)`, which serializes calls
  and supplies the per-VM socket path. Tests inject a recording stand-in.

  Cold boot:  await ready -> PUT machine-config -> PUT boot-source ->
              PUT each drive -> PUT each NIC -> InstanceStart.
  Restore:    await ready -> load snapshot (resume).

  Any step returning `{:error, _}` aborts the sequence and is returned verbatim.
  """

  alias Hyper.Firecracker.Api.{InstanceActionInfo, Operations, Vm}
  alias Hyper.Node.FireVMM.BootSpec

  @type run :: ((keyword() -> term()) -> term())

  @default_ready_timeout_ms 10_000
  @default_ready_interval_ms 50

  @spec boot(run(), Hyper.vm_source(), Hyper.Vm.Instance.t(), keyword()) :: :ok | {:error, term()}
  def boot(run, source, type, opts \\ []) when is_function(run, 1) do
    with {:ok, spec} <- BootSpec.resolve(source, type),
         {:ok, info} <- await_ready(run, opts) do
      # A re-adopted daemon (controller restarted, daemon survived) may already
      # be running; re-issuing pre-boot config would 400 and get the live guest
      # killed by the controller's stop-on-failure. A freshly-launched daemon
      # reports "Not started", so only then do we configure + start.
      if instance_started?(info), do: :ok, else: apply_spec(run, spec)
    end
  end

  @spec pause(run()) :: :ok | {:error, term()}
  def pause(run), do: set_vm_state(run, "Paused")

  @spec resume(run()) :: :ok | {:error, term()}
  def resume(run), do: set_vm_state(run, "Resumed")

  # --- internals -----------------------------------------------------------

  @spec apply_spec(run(), BootSpec.Cold.t() | BootSpec.Restore.t()) :: :ok | {:error, term()}
  defp apply_spec(run, %BootSpec.Cold{} = cold) do
    with :ok <- run.(fn opts -> Operations.put_machine_configuration(cold.machine_config, opts) end),
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

  # Poll describe_instance until the daemon's API answers, or the deadline lapses.
  # A `{:ok, _}` means the socket is up and serving; transport errors mean "not
  # yet". `ready_timeout_ms`/`ready_interval_ms` are overridable (tests use 0).
  @spec await_ready(run(), keyword()) :: {:ok, map()} | {:error, :daemon_unready}
  defp await_ready(run, opts) do
    timeout = Keyword.get(opts, :ready_timeout_ms, @default_ready_timeout_ms)
    interval = Keyword.get(opts, :ready_interval_ms, @default_ready_interval_ms)
    deadline = System.monotonic_time(:millisecond) + timeout
    poll_ready(run, deadline, interval)
  end

  @spec poll_ready(run(), integer(), non_neg_integer()) :: {:ok, map()} | {:error, :daemon_unready}
  defp poll_ready(run, deadline, interval) do
    case run.(&Operations.describe_instance/1) do
      {:ok, info} ->
        {:ok, info}

      {:error, _reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :daemon_unready}
        else
          Process.sleep(interval)
          poll_ready(run, deadline, interval)
        end
    end
  end
end
