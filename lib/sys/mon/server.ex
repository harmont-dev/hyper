defmodule Sys.Mon.Server do
  @moduledoc """
  Generic monitor process: drives a `Sys.Mon.Sampler` on a fixed period, folds
  each reading through a `Controls.Ewma` low-pass filter, and answers `value/1`.

  Ticks self-schedule with `Process.send_after` *after* each sample completes, so
  a slow sample cannot let ticks pile up. `dt` for the filter is measured with
  `System.monotonic_time/1`, so the EWMA gain stays correct under jitter.
  """

  use GenServer
  require Logger

  alias Controls.Ewma

  defmodule Reading do
    @moduledoc """
    A monitor reading: the latest instantaneous and filtered values, each in the
    sampler's domain type (a number or any `Unit.Quantity`).
    """
    @type t :: %__MODULE__{instant: Ewma.sample() | nil, smoothed: Ewma.sample() | nil}
    defstruct [:instant, :smoothed]
  end

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            sampler: module(),
            sampler_state: term(),
            period_ms: pos_integer(),
            ewma: Ewma.t(),
            last_mono: integer() | nil,
            instant: Ewma.sample() | nil
          }
    @enforce_keys [:sampler, :sampler_state, :period_ms, :ewma]
    defstruct [:sampler, :sampler_state, :period_ms, :ewma, :last_mono, :instant]
  end

  @doc """
  Start the monitor for `sampler`, registered under the sampler's own module name.

  The sampler module fully describes the monitor: `Sys.Mon.Server` reads its
  schedule from `period/0` and `tau/0`.
  """
  @spec start_link(module()) :: GenServer.on_start()
  def start_link(sampler) do
    GenServer.start_link(__MODULE__, sampler, name: sampler)
  end

  @doc "The latest instantaneous + filtered reading."
  @spec value(GenServer.server()) :: Reading.t()
  def value(server), do: GenServer.call(server, :value)

  @doc "Force a single synchronous sample and return the resulting reading. Mainly for tests."
  @spec sample_now(GenServer.server()) :: Reading.t()
  def sample_now(server), do: GenServer.call(server, :sample_now)

  @impl true
  def init(sampler) do
    case sampler.init() do
      {:ok, sampler_state} ->
        period_ms = Unit.Time.as_ms(sampler.period())
        _ = Process.send_after(self(), :tick, period_ms)

        {:ok,
         %State{
           sampler: sampler,
           sampler_state: sampler_state,
           period_ms: period_ms,
           ewma: Ewma.new(Unit.Time.as_ms(sampler.tau())),
           last_mono: nil,
           instant: nil
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
