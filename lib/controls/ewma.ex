defmodule Controls.Ewma do
  @moduledoc """
  First-order exponential moving average — a discrete low-pass filter (LPF) with
  an irregular-sampling-correct gain.

  The continuous first-order LPF `τ·ẏ + y = x` has the exact discrete solution,
  for a step-held input over an interval `Δt`:

      α  = 1 − exp(−Δt/τ)
      yₙ = α·xₙ + (1−α)·yₙ₋₁

  Deriving `α` from the *measured* `Δt` (never a hardcoded constant) pins the
  filter's cutoff at `1/(2πτ)` regardless of scheduler jitter or differing
  per-monitor sample periods. `τ` (`tau_ms`) is the time constant: the output
  reaches ~63 % of a step after one `τ` and ~95 % after `3τ`. The first sample
  seeds the filter directly, avoiding a warm-up ramp from zero.
  """

  @enforce_keys [:tau_ms]
  defstruct [:tau_ms, value: nil]

  @type t :: %__MODULE__{tau_ms: pos_integer(), value: float() | nil}

  @doc "Build a filter with time constant `tau_ms` (milliseconds)."
  @spec new(pos_integer()) :: t()
  def new(tau_ms) when is_integer(tau_ms) and tau_ms > 0 do
    %__MODULE__{tau_ms: tau_ms}
  end

  @doc """
  Fold one `sample`, taken `dt_ms` after the previous one, into the filter.

  The first sample seeds the average (its `dt_ms` is ignored).
  """
  @spec update(t(), number(), pos_integer()) :: t()
  def update(%__MODULE__{value: nil} = e, sample, _dt_ms) do
    %{e | value: sample * 1.0}
  end

  def update(%__MODULE__{tau_ms: tau, value: prev} = e, sample, dt_ms)
      when is_integer(dt_ms) and dt_ms > 0 do
    alpha = 1.0 - :math.exp(-dt_ms / tau)
    %{e | value: alpha * sample + (1.0 - alpha) * prev}
  end

  @doc "The current filtered value, or `nil` before the first sample."
  @spec value(t()) :: float() | nil
  def value(%__MODULE__{value: v}), do: v
end
