defmodule Hyper.Cfg.Mon do
  @moduledoc """
  Sampling cadence for the `/proc`-backed monitors (`Sys.Mon.*`).

  Each metric has a deliberately co-prime sampling period (so the four monitors
  rarely sample on the same tick) and an EWMA time constant. Operators may
  override per metric via `config :hyper, Hyper.Cfg.Mon, cpu: [period_ms: ..,
  tau_s: ..]` (plain integers, ms and s); the defaults below are the tuned
  values. The accessors return `Unit.Time` quantities — `Sys.Mon.Server`
  consumes them via `Unit.Time.as_ms/1`.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

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
  defp field(metric, key) do
    default = @defaults |> Map.fetch!(metric) |> Keyword.fetch!(key)

    case get_cfg(runtime: {__MODULE__, metric}, default: []) do
      kw when is_list(kw) -> Keyword.get(kw, key, default)
      _ -> default
    end
  end
end
