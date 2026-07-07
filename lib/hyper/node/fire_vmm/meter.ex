defmodule Hyper.Node.FireVMM.Meter do
  @moduledoc """
  Per-VM compute meter: samples the VM's cgroup `cpu.stat` every second,
  accrues the CPU time actually executed, and flushes one
  `Hyper.Metering.Usage` window per minute — plus a final one at teardown.
  The meter is the FireVMM supervisor's **last** child, so at shutdown it
  stops **first**, taking its final reading before the Daemon removes the
  cgroup.

  Billing-grade by construction:

    * consumption is accrued from counter deltas (`Controls.Accumulator`), so
      a cgroup recreated by a Core restart re-baselines instead of going
      negative;
    * a failed flush keeps the accrued time and retries with the window
      extended; the retry is idempotent on `(vm_id, window_start)`, so an
      insert that committed but errored client-side is dropped, not
      double-billed — recorded usage can never be counted twice;
    * every failure mode (meter crash, node crash, unreadable cgroup) loses at
      most the unflushed window: metering only ever under-counts, never
      over-counts.
  """

  use GenServer
  use OpenTelemetryDecorator

  alias Controls.Accumulator
  alias Hyper.Cluster.Routing
  alias Sys.Linux.Cgroup.V2.CpuStat
  alias Unit.Time

  require Logger

  @sample_interval Time.s(1)
  @flush_interval Time.s(60)

  defmodule Opts do
    @moduledoc "Meter wiring: the VM, its cgroup leaf, and the usage sink."

    @enforce_keys [:vm_id, :cgroup_dir]
    defstruct [
      :vm_id,
      :cgroup_dir,
      sink: &Hyper.Metering.Usage.record/1,
      register?: true
    ]

    @type t :: %__MODULE__{
            vm_id: Hyper.Vm.Id.t(),
            cgroup_dir: Path.t(),
            sink: (Hyper.Metering.Usage.attrs() -> :ok | {:error, term()}),
            register?: boolean()
          }
  end

  defstruct [:opts, :acc, :window_start, :ticks]

  @spec child_spec(Opts.t()) :: Supervisor.child_spec()
  def child_spec(%Opts{} = opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :permanent}
  end

  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  CPU time accrued by `vm_id`'s meter but not yet flushed to the usage table.
  `Unit.Time.zero()` when no meter is reachable (VM stopped, meter mid-restart)
  — callers fall back to the flushed record, an under-count of at most one
  flush window.
  """
  @spec unflushed(Hyper.Vm.Id.t()) :: Time.t()
  def unflushed(vm_id) do
    GenServer.call(Routing.via({vm_id, :meter}), :unflushed)
  catch
    :exit, _reason -> Time.zero()
  end

  @doc false
  @spec sample_now(GenServer.server()) :: :ok
  def sample_now(server), do: GenServer.call(server, :sample_now)

  @doc false
  @spec flush_now(GenServer.server()) :: :ok
  def flush_now(server), do: GenServer.call(server, :flush_now)

  @impl true
  def init(%Opts{} = opts) do
    # Trap exits so terminate/2 runs on supervisor shutdown and can flush the
    # final window before the Daemon removes the cgroup.
    Process.flag(:trap_exit, true)

    case register(opts) do
      :ok ->
        _ = schedule_tick()

        {:ok,
         %__MODULE__{
           opts: opts,
           acc: Accumulator.new(Time.zero()),
           window_start: DateTime.utc_now(),
           ticks: 0
         }}

      {:error, reason} ->
        # A stale dead incarnation still holds the routing name; decline and
        # let the supervisor retry once Horde has reaped it.
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:tick, state) do
    state = state |> sample() |> tick_flush()
    _ = schedule_tick()
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_call(:unflushed, _from, state) do
    {:reply, Accumulator.total(state.acc), state}
  end

  def handle_call(:sample_now, _from, state), do: {:reply, :ok, sample(state)}
  def handle_call(:flush_now, _from, state), do: {:reply, :ok, flush(state)}

  @impl true
  @decorate with_span("Hyper.Node.FireVMM.Meter.terminate", include: [])
  def terminate(_reason, state) do
    state |> sample() |> flush()
  end

  @spec register(Opts.t()) :: :ok | {:error, term()}
  defp register(%Opts{register?: false}), do: :ok
  defp register(%Opts{vm_id: vm_id}), do: Routing.register_self({vm_id, :meter})

  @spec sample(%__MODULE__{}) :: %__MODULE__{}
  defp sample(%__MODULE__{opts: opts} = state) do
    case CpuStat.read(opts.cgroup_dir) do
      {:ok, %CpuStat{usage: usage}} ->
        %{state | acc: Accumulator.observe(state.acc, usage)}

      # The leaf may not exist yet (jailer still starting) or be mid-recreation
      # (Core restart). Skip; the accumulator's reset handling re-baselines on
      # the next successful read.
      {:error, _reason} ->
        state
    end
  end

  @spec tick_flush(%__MODULE__{}) :: %__MODULE__{}
  defp tick_flush(%__MODULE__{ticks: ticks} = state) do
    if ticks + 1 >= flush_every() do
      %{flush(state) | ticks: 0}
    else
      %{state | ticks: ticks + 1}
    end
  end

  @spec flush(%__MODULE__{}) :: %__MODULE__{}
  defp flush(%__MODULE__{opts: opts} = state) do
    window_end = DateTime.utc_now()
    accrued = Accumulator.total(state.acc)

    cond do
      Time.as_us(accrued) == 0 ->
        %{state | window_start: window_end}

      record(opts, state.window_start, window_end, accrued) == :ok ->
        %{state | acc: Accumulator.flush(state.acc), window_start: window_end}

      true ->
        # Keep the accrued time; the next flush retries with the window
        # extended, so a transient sink failure never drops usage.
        state
    end
  end

  @spec record(Opts.t(), DateTime.t(), DateTime.t(), Time.t()) :: :ok | :error
  defp record(%Opts{} = opts, window_start, window_end, cpu_time) do
    attrs = %{
      vm_id: opts.vm_id,
      node_id: to_string(node()),
      window_start: window_start,
      window_end: window_end,
      cpu_time: cpu_time
    }

    case opts.sink.(attrs) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("vm #{opts.vm_id}: usage flush failed: #{inspect(reason)}")
        :error
    end
  end

  @spec schedule_tick() :: reference()
  defp schedule_tick do
    Process.send_after(self(), :tick, Time.as_ms(@sample_interval))
  end

  @spec flush_every() :: pos_integer()
  defp flush_every, do: div(Time.as_ns(@flush_interval), Time.as_ns(@sample_interval))
end
