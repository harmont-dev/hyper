defmodule Sys.Mon.Cpu do
  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Stat
  alias Sys.Mon.Server
  alias Unit.Time

  @period_s 2
  @tau_s 30

  @moduledoc """
  Monitors instantaneous CPU utilization (the soft beta_vcpus signal).

  Samples `/proc/stat` every #{@period_s} seconds and reports the busy fraction
  (`0.0..1.0`, normalized across all cores) between consecutive reads - never the
  load average, which has different semantics. The first read only establishes a
  baseline (`:skip`). Readings are smoothed with a #{@tau_s}-second time constant.

  Telemetry: `[:sys, :mon, :cpu]` with measurements `%{instant: float, smoothed: float}`.
  """

  @period Time.s(@period_s)
  @tau Time.s(@tau_s)
  @event [:sys, :mon, :cpu]

  @doc "The latest instantaneous + filtered CPU utilization (fractions `0.0..1.0`)."
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
  # snapshot. A non-positive interval (no elapsed jiffies) yields `0.0`.
  @spec utilization(Stat.Snapshot.t(), Stat.Snapshot.t()) :: float()
  defp utilization(%Stat.Snapshot{idle: i0, total: t0}, %Stat.Snapshot{idle: i1, total: t1}) do
    dt = t1 - t0
    di = i1 - i0

    if dt <= 0 do
      0.0
    else
      ((dt - di) / dt)
      |> max(0.0)
      |> min(1.0)
    end
  end
end
