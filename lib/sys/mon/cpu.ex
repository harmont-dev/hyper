defmodule Sys.Mon.Cpu do
  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Stat
  alias Sys.Mon.Server

  @moduledoc """
  Monitors instantaneous CPU utilization (the soft beta_vcpus signal).

  Samples `/proc/stat` every 23 ms and reports the busy fraction
  (`0.0..1.0`, normalized across all cores) between consecutive reads - never the
  load average, which has different semantics. The first read only establishes a
  baseline (`:skip`). Readings are smoothed with a 30-second time constant
  (sampling fast only de-noises the filter; the smoothing window is set by `tau`).
  """

  @impl true
  @spec period :: Unit.Time.t()
  def period, do: Hyper.Cfg.Mon.period(:cpu)

  @impl true
  @spec tau :: Unit.Time.t()
  def tau, do: Hyper.Cfg.Mon.tau(:cpu)

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
          %Stat.Snapshot{cpu: prev} -> {:ok, utilization(prev, snapshot.cpu), snapshot}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # Busy fraction (`0.0..1.0`) between an earlier and a later aggregate-CPU
  # `CpuTimes`. A non-positive interval (no elapsed jiffies, or counters that
  # did not advance) yields `0.0`; the ratio is clamped into `0.0..1.0` so a
  # transient counter quirk can never produce an out-of-range reading.
  @spec utilization(Stat.CpuTimes.t(), Stat.CpuTimes.t()) :: float()
  def utilization(earlier, later) do
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
