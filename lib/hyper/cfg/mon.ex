defmodule Hyper.Cfg.Mon do
  @moduledoc """
  Sampling cadence for the `/proc`-backed monitors (`Sys.Mon.*`).

  Each metric has a deliberately co-prime sampling period (so the four monitors
  rarely sample on the same tick) and an EWMA time constant. These are tuned
  internals of the monitoring subsystem, not operator configuration — they are
  fixed here. The accessors return `Unit.Time` quantities — `Sys.Mon.Server`
  consumes them via `Unit.Time.as_ms/1`.
  """

  @type metric :: :cpu | :mem | :disk_bw | :net_bw

  @defaults %{
    cpu: [period_ms: 23, tau_s: 30],
    mem: [period_ms: 29, tau_s: 30],
    disk_bw: [period_ms: 31, tau_s: 20],
    net_bw: [period_ms: 37, tau_s: 20]
  }

  @doc "Sampling period for `metric`."
  @spec period(metric()) :: Unit.Time.t()
  def period(metric), do: Unit.Time.ms(field(metric, :period_ms))

  @doc "EWMA smoothing time constant for `metric`."
  @spec tau(metric()) :: Unit.Time.t()
  def tau(metric), do: Unit.Time.s(field(metric, :tau_s))

  @spec field(metric(), atom()) :: pos_integer()
  defp field(metric, key), do: @defaults |> Map.fetch!(metric) |> Keyword.fetch!(key)
end
