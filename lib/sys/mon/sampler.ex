defmodule Sys.Mon.Sampler do
  @moduledoc """
  Behaviour for a single soft-metric probe.

  A sampler is the I/O-bearing source of instantaneous readings driven by
  `Sys.Mon.Server`. It may carry private state between samples (e.g. the previous
  `/proc/stat` snapshot needed to turn cumulative counters into a rate). All
  readings are plain floats in the sampler's natural unit (a fraction for CPU,
  bytes for memory, bytes/sec for bandwidth); the owning monitor re-applies a
  domain `Unit.*` at its public boundary.
  """

  @typedoc "Sampler-private carry-over state."
  @type private :: term()

  @typedoc "An instantaneous reading in the sampler's natural unit."
  @type reading :: float()

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
