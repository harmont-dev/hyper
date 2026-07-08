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
    * the accumulator is baselined at meter **start**, not at the first
      periodic tick: a leaf that already exists is baselined on its current
      reading (a restarted meter never re-bills usage a previous incarnation
      flushed), and a leaf the jailer has not yet created is baselined at
      zero (its counter is born at zero), so a VM that lives and dies inside
      one sample interval still has its whole life covered by the final
      reading in `terminate/2`;
    * a failed flush keeps the accrued time and retries with the window
      extended; the retry is idempotent on `(vm_id, window_start)`, so an
      insert that committed but errored client-side is dropped, not
      double-billed — recorded usage can never be counted twice;
    * every failure mode (meter crash, node crash, unreadable cgroup) loses at
      most the unflushed window: metering only ever under-counts, never
      over-counts.

  Observability contract: because empty windows are dropped without a write,
  every drop is logged with the meter's lifetime sample/window counters. A
  drop on a VM that has already recorded usage is a normal idle window and
  logs at `debug`; a drop on a VM that has **never** recorded a window means
  the VM's entire life produced no usage row — every cgroup read failed, or
  the guest genuinely burned no measurable CPU after the start-of-life
  baseline — and logs at `warning`. Per-sample `cpu.stat` read failures log
  at `debug` (they are expected while the jailer is still creating the leaf)
  and are counted.
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

  defstruct [
    :opts,
    :acc,
    :window_start,
    :ticks,
    samples_ok: 0,
    samples_failed: 0,
    last_sample_error: nil,
    windows_recorded: 0,
    windows_dropped: 0
  ]

  @spec child_spec(Opts.t()) :: Supervisor.child_spec()
  def child_spec(%Opts{} = opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :permanent,
      # Must outlast DBConnection's 15s query timeout: terminate/2 flushes the
      # final usage window to Postgres, and the OTP default 5s would
      # brutal-kill a slow teardown INSERT mid-write, losing the window.
      shutdown: Time.as_ms(Time.s(20))
    }
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
        state =
          initial_state(%__MODULE__{
            opts: opts,
            acc: Accumulator.new(Time.zero()),
            window_start: DateTime.utc_now(),
            ticks: 0
          })

        _ = schedule_tick()
        {:ok, state}

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

  # Baseline the counter at the meter's birth, not at the first tick. A leaf
  # that already exists may hold usage a previous meter incarnation flushed —
  # baseline on its current reading, so a restarted meter never re-bills. A
  # leaf that does not exist yet can only be created after us, so its counter
  # is born at zero: baseline zero, and the first successful read accrues the
  # boot burn — a VM stopped before its first tick still records a real window.
  # The birth read participates in the observability counters like any sample.
  @spec initial_state(%__MODULE__{}) :: %__MODULE__{}
  defp initial_state(%__MODULE__{opts: opts} = state) do
    case CpuStat.read(opts.cgroup_dir) do
      {:ok, %CpuStat{usage: usage}} ->
        %{state | acc: Accumulator.observe(state.acc, usage), samples_ok: 1}

      {:error, reason} ->
        Logger.debug("vm #{opts.vm_id}: cpu.stat sample failed: #{inspect(reason)}")

        %{
          state
          | acc: Accumulator.observe(state.acc, Time.zero()),
            samples_failed: 1,
            last_sample_error: reason
        }
    end
  end

  @spec sample(%__MODULE__{}) :: %__MODULE__{}
  defp sample(%__MODULE__{opts: opts} = state) do
    case CpuStat.read(opts.cgroup_dir) do
      {:ok, %CpuStat{usage: usage}} ->
        %{state | acc: Accumulator.observe(state.acc, usage), samples_ok: state.samples_ok + 1}

      # The leaf may not exist yet (jailer still starting) or be mid-recreation
      # (Core restart). Skip; the accumulator's reset handling re-baselines on
      # the next successful read.
      {:error, reason} ->
        Logger.debug("vm #{opts.vm_id}: cpu.stat sample failed: #{inspect(reason)}")
        %{state | samples_failed: state.samples_failed + 1, last_sample_error: reason}
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
        log_dropped_window(state, window_end)
        %{state | window_start: window_end, windows_dropped: state.windows_dropped + 1}

      record(opts, state.window_start, window_end, accrued) == :ok ->
        %{
          state
          | acc: Accumulator.flush(state.acc),
            window_start: window_end,
            windows_recorded: state.windows_recorded + 1
        }

      true ->
        # Keep the accrued time; the next flush retries with the window
        # extended, so a transient sink failure never drops usage.
        state
    end
  end

  # An idle VM legitimately accrues nothing between flushes, but a meter that
  # drops a window having never recorded one means the VM has produced no
  # usage row at all — that is operator-visible, not routine. Warn only on
  # the FIRST such drop: the fingerprint's value is in the first occurrence,
  # and a long-lived never-active VM (or a wedged jailer) would otherwise
  # repeat the warning every window for its whole life.
  @spec log_dropped_window(%__MODULE__{}, DateTime.t()) :: :ok
  defp log_dropped_window(
         %__MODULE__{windows_recorded: 0, windows_dropped: 0} = state,
         window_end
       ) do
    Logger.warning(
      "vm #{state.opts.vm_id}: dropping empty usage window with no usage " <>
        "ever recorded (#{dropped_window_detail(state, window_end)})"
    )
  end

  defp log_dropped_window(%__MODULE__{} = state, window_end) do
    Logger.debug(
      "vm #{state.opts.vm_id}: dropping empty usage window " <>
        "(#{dropped_window_detail(state, window_end)})"
    )
  end

  @spec dropped_window_detail(%__MODULE__{}, DateTime.t()) :: String.t()
  defp dropped_window_detail(%__MODULE__{} = state, window_end) do
    window_ms = DateTime.diff(window_end, state.window_start, :millisecond)

    "window #{window_ms}ms; since meter start: #{state.samples_ok} ok/" <>
      "#{state.samples_failed} failed cgroup samples, #{state.windows_recorded} recorded/" <>
      "#{state.windows_dropped} dropped windows#{last_sample_error_detail(state)}"
  end

  @spec last_sample_error_detail(%__MODULE__{}) :: String.t()
  defp last_sample_error_detail(%__MODULE__{last_sample_error: nil}), do: ""

  defp last_sample_error_detail(%__MODULE__{last_sample_error: reason}),
    do: ", last sample error: #{inspect(reason)}"

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
