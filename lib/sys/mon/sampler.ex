defmodule Sys.Mon.Sampler do
  @moduledoc """
  Behaviour for a single soft-metric probe.

  A sampler is the I/O-bearing source of instantaneous readings driven by
  `Sys.Mon.Server`. It may carry private state between samples (e.g. the previous
  `/proc/stat` snapshot needed to turn cumulative counters into a rate).

  A reading is whatever domain value the sampler chooses, as long as it implements
  `Controls.Linear` so `Sys.Mon.Server` can low-pass-filter it: a `Unit.Information`
  for memory, a `Unit.Bandwidth` for throughput, a bare `Float` fraction for CPU.
  The value flows through the filter and out of the monitor unchanged - no
  float-only bottleneck.
  """

  @typedoc "Sampler-private carry-over state."
  @type private :: term()

  @typedoc "An instantaneous reading; any `Controls.Linear` value."
  @type reading :: Controls.Linear.t()

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
