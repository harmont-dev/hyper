defmodule Hyper.Node.Reaper.Config do
  @moduledoc """
  Configuration for the per-node resource reaper (`Hyper.Node.Reaper`).

  Every field has a default, so configuration is optional - set only what you want
  to change. Durations are `Unit.Time` values, so (like `Hyper.Img.Db.Gc.Config`)
  overrides belong in `config/runtime.exs`:

      config :hyper, Hyper.Node.Reaper.Config,
        enabled: true,
        interval: Unit.Time.s(30)

  Set `enabled: false` to turn the reaper off entirely - it then never starts.

  ## Fields

    * `enabled` - run the reaper at all (default `true`).
    * `interval` - rest between reap ticks (default `60s`). The two-strike grace
      means an orphan is reaped at most one interval after it is first seen.
  """

  @type t :: %__MODULE__{
          enabled: boolean(),
          interval: Unit.Time.t()
        }

  defstruct enabled: true,
            interval: Unit.Time.s(60)

  @doc "Build the config from app env, filling any unset field with its default."
  @spec load() :: t()
  def load do
    struct!(__MODULE__, Application.get_env(:hyper, __MODULE__, []))
  end
end
