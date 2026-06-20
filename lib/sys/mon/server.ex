defmodule Sys.Mon.Server do
  @moduledoc """
  Generic monitor process: drives a `Sys.Mon.Sampler` on a fixed period, folds
  each reading through a `Controls.Ewma` low-pass filter, emits a `:telemetry`
  event, and answers `value/1`.

  Ticks self-schedule with `Process.send_after` *after* each sample completes, so
  a slow sample cannot let ticks pile up. `Δt` for the filter is measured with
  `System.monotonic_time/1`, so the EWMA gain stays correct under jitter.
  """

  use GenServer
  require Logger

  alias Controls.Ewma

  defmodule Reading do
    @moduledoc "A monitor reading: the latest instantaneous and filtered values (raw floats)."
    @type t :: %__MODULE__{instant: float() | nil, smoothed: float() | nil}
    defstruct [:instant, :smoothed]
  end

  defmodule Opts do
    @moduledoc "Start options for a `Sys.Mon.Server`."
    @type t :: %__MODULE__{
            sampler: module(),
            period: Unit.Time.t(),
            tau: Unit.Time.t(),
            name: GenServer.name(),
            telemetry_event: [atom()]
          }
    @enforce_keys [:sampler, :period, :tau, :name, :telemetry_event]
    defstruct [:sampler, :period, :tau, :name, :telemetry_event]
  end

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            sampler: module(),
            sampler_state: term(),
            period_ms: pos_integer(),
            ewma: Ewma.t(),
            last_mono: integer() | nil,
            instant: float() | nil,
            telemetry_event: [atom()]
          }
    @enforce_keys [:sampler, :sampler_state, :period_ms, :ewma, :telemetry_event]
    defstruct [
      :sampler,
      :sampler_state,
      :period_ms,
      :ewma,
      :last_mono,
      :instant,
      :telemetry_event
    ]
  end

  @doc "Start a monitor for the sampler described by `opts`."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{name: name} = opts) do
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "The latest instantaneous + filtered reading."
  @spec value(GenServer.server()) :: Reading.t()
  def value(server), do: GenServer.call(server, :value)

  @doc "Force a single synchronous sample and return the resulting reading. Mainly for tests."
  @spec sample_now(GenServer.server()) :: Reading.t()
  def sample_now(server), do: GenServer.call(server, :sample_now)

  @impl true
  def init(%Opts{} = opts) do
    case opts.sampler.init() do
      {:ok, sampler_state} ->
        period_ms = Unit.Time.as_ms(opts.period)
        _ = Process.send_after(self(), :tick, period_ms)

        {:ok,
         %State{
           sampler: opts.sampler,
           sampler_state: sampler_state,
           period_ms: period_ms,
           ewma: Ewma.new(Unit.Time.as_ms(opts.tau)),
           last_mono: nil,
           instant: nil,
           telemetry_event: opts.telemetry_event
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:value, _from, state), do: {:reply, reading(state), state}

  @impl true
  def handle_call(:sample_now, _from, state) do
    state = do_sample(state)
    {:reply, reading(state), state}
  end

  @impl true
  def handle_info(:tick, state) do
    state = do_sample(state)
    _ = Process.send_after(self(), :tick, state.period_ms)
    {:noreply, state}
  end

  # Take one reading from the sampler and fold it into the filter.
  @spec do_sample(State.t()) :: State.t()
  defp do_sample(state) do
    now = System.monotonic_time(:millisecond)

    case state.sampler.sample(state.sampler_state) do
      {:ok, x, sampler_state} ->
        dt = if state.last_mono, do: max(now - state.last_mono, 1), else: state.period_ms
        ewma = Ewma.update(state.ewma, x, dt)
        :telemetry.execute(state.telemetry_event, %{instant: x, smoothed: Ewma.value(ewma)}, %{})
        %{state | sampler_state: sampler_state, ewma: ewma, instant: x, last_mono: now}

      {:skip, sampler_state} ->
        %{state | sampler_state: sampler_state, last_mono: now}

      {:error, reason} ->
        Logger.warning("#{inspect(state.sampler)} sample failed: #{inspect(reason)}")
        state
    end
  end

  @spec reading(State.t()) :: Reading.t()
  defp reading(state) do
    %Reading{instant: state.instant, smoothed: Ewma.value(state.ewma)}
  end
end
