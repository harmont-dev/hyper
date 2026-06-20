defmodule Sys.Mon.DiskBw do
  @moduledoc """
  Monitors instantaneous disk bandwidth (the soft beta_disk_bw signal).

  Samples cumulative read+write bytes across whole physical disks from
  `/proc/diskstats` every 7 seconds and differentiates them into bytes/sec via
  `Controls.Rate` (the first read only establishes a baseline). The rate series is
  smoothed with a 20-second time constant. Readings are `Unit.Bandwidth`.

  Telemetry: `[:sys, :mon, :disk_bw]` with measurements `%{instant: float, smoothed: float}` (bytes/sec).
  """

  @behaviour Sys.Mon.Sampler

  alias Controls.Rate
  alias Sys.Linux.Proc.Diskstats
  alias Sys.Mon.Server
  alias Unit.Bandwidth
  alias Unit.Time

  @period Time.s(7)
  @tau Time.s(20)
  @event [:sys, :mon, :disk_bw]

  @doc "The latest instantaneous + filtered disk bandwidth (`Unit.Bandwidth` readings)."
  @spec value() :: Server.Reading.t()
  def value, do: Server.value(__MODULE__)

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    opts = %Server.Opts{
      sampler: __MODULE__,
      period: @period,
      tau: @tau,
      name: __MODULE__,
      telemetry_event: @event
    }

    %{id: __MODULE__, start: {Server, :start_link, [opts]}}
  end

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(rate_state) do
    case Diskstats.read_total_physical() do
      {:ok, bytes} ->
        rate_state
        |> Rate.compute(bytes, System.monotonic_time(:millisecond))
        |> as_bandwidth()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Project the raw bytes/sec rate into a `Unit.Bandwidth` reading.
  @spec as_bandwidth({:ok, float(), Rate.state()} | {:skip, Rate.state()}) ::
          {:ok, Bandwidth.t(), Rate.state()} | {:skip, Rate.state()}
  defp as_bandwidth({:ok, bytes_per_sec, state}),
    do: {:ok, Bandwidth.bps(round(bytes_per_sec)), state}

  defp as_bandwidth({:skip, state}), do: {:skip, state}
end
