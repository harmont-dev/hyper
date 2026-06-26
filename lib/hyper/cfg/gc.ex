defmodule Hyper.Cfg.Gc do
  @moduledoc """
  Configuration for the layer garbage collector (`Hyper.Img.Db.Gc`).

  Every field has a default, so configuration is optional - set only what you want
  to change. Durations are `Unit.Time` values, so (like `Hyper.Cfg.Budget`)
  overrides belong in `config/runtime.exs`:

      config :hyper, Hyper.Cfg.Gc,
        enabled: true,
        sweep_interval: Unit.Time.s(30),
        grace_period: Unit.Time.s(60 * 60)

  Set `enabled: false` to turn the collector off entirely - it then never starts.

  ## Fields

    * `enabled` - run the collector at all (default `true`).
    * `batch_size` - rows per keyset page (default `200`).
    * `batch_pause` - pause between pages within a sweep (default `100ms`).
    * `sweep_interval` - rest between completed sweeps (default `60s`).
    * `acquire_interval` - how often a standby retries to become active (default `5s`).
    * `retry` - backoff after the medium or database is unavailable (default `60s`).
    * `statement_timeout` - cap on each GC DB statement so it can't pin a backend
      (default `5s`).
    * `grace_period` - never prune a blob younger than this, so a row whose file is
      still being published is safe (default `1h`).
  """

  @type t :: %__MODULE__{
          enabled: boolean(),
          batch_size: pos_integer(),
          batch_pause: Unit.Time.t(),
          sweep_interval: Unit.Time.t(),
          acquire_interval: Unit.Time.t(),
          retry: Unit.Time.t(),
          statement_timeout: Unit.Time.t(),
          grace_period: Unit.Time.t()
        }

  defstruct enabled: true,
            batch_size: 200,
            batch_pause: Unit.Time.ms(100),
            sweep_interval: Unit.Time.s(60),
            acquire_interval: Unit.Time.s(5),
            retry: Unit.Time.s(60),
            statement_timeout: Unit.Time.s(5),
            grace_period: Unit.Time.s(60 * 60)

  @doc "Build the config from app env, filling any unset field with its default."
  @spec load() :: t()
  def load do
    struct!(__MODULE__, Application.get_env(:hyper, __MODULE__, []))
  end
end
