defmodule Sys.Mon.Cpu do
  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Stat
  alias Sys.Mon.Server
  alias Unit.Time

  @period_ms 23
  @tau_s 30
  @event [:sys, :mon, :cpu]

  @moduledoc """
  Monitors instantaneous CPU utilization (the soft beta_vcpus signal).

  Samples `/proc/stat` every #{@period_ms} ms and reports the busy fraction
  (`0.0..1.0`, normalized across all cores) between consecutive reads - never the
  load average, which has different semantics. The first read only establishes a
  baseline (`:skip`). Readings are smoothed with a #{@tau_s}-second time constant
  (sampling fast only de-noises the filter; the smoothing window is set by `tau`).

  Telemetry: `#{inspect(@event)}` with measurements `%{instant: float, smoothed: float}`.
  """

  @impl true
  def period, do: Time.ms(@period_ms)

  @impl true
  def tau, do: Time.s(@tau_s)

  @impl true
  def telemetry_event, do: @event

  @doc "The latest instantaneous + filtered CPU utilization (fractions `0.0..1.0`)."
  @spec value() :: Server.Reading.t()
  def value, do: Server.value(__MODULE__)

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: %{id: __MODULE__, start: {Server, :start_link, [__MODULE__]}}

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(prev_snapshot) do
    case Stat.read() do
      {:ok, snapshot} ->
        case prev_snapshot do
          nil -> {:skip, snapshot}
          prev -> {:ok, utilization(prev, snapshot), snapshot}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Busy fraction (`0.0..1.0`) between an earlier and a later `/proc/stat`
  # snapshot, computed from the aggregate CPU times. A non-positive interval (no
  # elapsed jiffies) yields `0.0`.
  @spec utilization(Stat.Snapshot.t(), Stat.Snapshot.t()) :: float()
  defp utilization(%Stat.Snapshot{cpu: earlier}, %Stat.Snapshot{cpu: later}) do
    dt = Stat.CpuTimes.total(later) - Stat.CpuTimes.total(earlier)
    di = Stat.CpuTimes.idle(later) - Stat.CpuTimes.idle(earlier)

    if dt <= 0 do
      0.0
    else
      ((dt - di) / dt)
      |> max(0.0)
      |> min(1.0)
    end
  end
end
