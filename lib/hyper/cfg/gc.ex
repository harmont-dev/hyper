defmodule Hyper.Cfg.Gc do
  @moduledoc """
  Layer garbage collector tuning. Each field reads from `config.exs`
  (`config :hyper, Hyper.Cfg.Gc, ...`), then the `[img.gc]` table, then its
  default. Durations are `Unit.Time` — Elixir terms in `config.exs`, strings
  (`"60s"`, `"1h"`) in TOML.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @type t :: %__MODULE__{
          enabled: boolean(),
          batch_size: pos_integer(),
          batch_pause: Unit.Time.t(),
          sweep_interval: Unit.Time.t(),
          acquire_interval: Unit.Time.t(),
          retry: Unit.Time.t(),
          timeout: Unit.Time.t(),
          grace_period: Unit.Time.t()
        }
  defstruct [
    :enabled,
    :batch_size,
    :batch_pause,
    :sweep_interval,
    :acquire_interval,
    :retry,
    :timeout,
    :grace_period
  ]

  @spec load :: t()
  def load do
    struct!(__MODULE__, [
      {:enabled, get_cfg(runtime: {__MODULE__, :enabled}, toml: "img.gc.enabled", default: true)},
      {:batch_size,
       get_cfg(runtime: {__MODULE__, :batch_size}, toml: "img.gc.batch_size", default: 200)},
      {:batch_pause, duration(:batch_pause, "img.gc.batch_pause", Unit.Time.ms(100))},
      {:sweep_interval, duration(:sweep_interval, "img.gc.sweep_interval", Unit.Time.s(60))},
      {:acquire_interval, duration(:acquire_interval, "img.gc.acquire_interval", Unit.Time.s(5))},
      {:retry, duration(:retry, "img.gc.retry", Unit.Time.s(60))},
      {:timeout, duration(:timeout, "img.gc.timeout", Unit.Time.s(5))},
      {:grace_period, duration(:grace_period, "img.gc.grace_period", Unit.Time.s(3600))}
    ])
  end

  defp duration(key, toml, default) do
    case get_cfg(runtime: {__MODULE__, key}, toml: toml, default: default) do
      %_mod{} = t -> t
      s when is_binary(s) -> Unit.Time.parse!(s)
    end
  end
end
