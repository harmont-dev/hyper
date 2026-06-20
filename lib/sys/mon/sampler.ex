defmodule Sys.Mon.Sampler do
  @moduledoc """
  Behaviour for a single soft-metric probe.

  A sampler is the I/O-bearing source of instantaneous readings driven by
  `Sys.Mon.Server`. It may carry private state between samples (e.g. the previous
  `/proc/stat` snapshot needed to turn cumulative counters into a rate).

  The sampler module *fully describes* its monitor: alongside the readings it
  declares its own schedule and telemetry identity (`period/0`, `tau/0`,
  `telemetry_event/0`), so `Sys.Mon.Server.start_link(SamplerModule)` needs nothing
  else.

  A reading is whatever domain value the sampler chooses - a number or any
  `Unit.Quantity` (a `Unit.Information` for memory, a `Unit.Bandwidth` for
  throughput, a bare `Float` fraction for CPU) - so `Sys.Mon.Server` can
  low-pass-filter it and it flows out of the monitor unchanged, with no float-only
  bottleneck.
  """

  @typedoc "Sampler-private carry-over state."
  @type private :: term()

  @typedoc "An instantaneous reading: a number or any `Unit.Quantity`."
  @type reading :: number() | Unit.Quantity.t()

  @doc "How often to sample."
  @callback period() :: Unit.Time.t()

  @doc "The low-pass filter time constant (the smoothing window, independent of `period/0`)."
  @callback tau() :: Unit.Time.t()

  @doc "The `:telemetry` event emitted on each successful sample."
  @callback telemetry_event() :: [atom()]

  @doc "Initialize sampler-private state."
  @callback init() :: {:ok, private()} | {:error, term()}

  @doc """
  Produce the next reading.

  `:skip` means a reading could not yet be formed (e.g. no baseline for a rate),
  and the filter is left untouched. `:error` is a transient failure to be logged.
  """
  @callback sample(private()) ::
              {:ok, reading(), private()} | {:skip, private()} | {:error, term()}
end
