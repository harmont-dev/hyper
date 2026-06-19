defmodule Sys.Mon.Cpu do
  @moduledoc """
  Monitors instantaneous CPU utilization (the soft β_vcpus signal).

  Samples `/proc/stat` every #{2} seconds and reports the busy fraction
  (`0.0..1.0`, normalized across all cores) between consecutive reads — never the
  load average, which has different semantics. The first read only establishes a
  baseline (`:skip`). Readings are smoothed with a 30-second time constant.

  Telemetry: `[:sys, :mon, :cpu]` with measurements `%{instant: float, smoothed: float}`.
  """

  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Stat
  alias Sys.Mon.Server
  alias Unit.Time

  @period Time.s(2)
  @tau Time.s(30)
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
          prev -> {:ok, Stat.utilization(prev, snapshot), snapshot}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
