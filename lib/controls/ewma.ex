defmodule Controls.Ewma do
  @moduledoc """
  First-order exponential moving average - a discrete low-pass filter (LPF) with
  an irregular-sampling-correct gain.

  The continuous first-order LPF `tau*y' + y = x` has the exact discrete solution,
  for a step-held input over an interval `dt`:

      alpha  = 1 - exp(-dt/tau)
      y_n = alpha*x_n + (1-alpha)*y_{n-1}

  Deriving `alpha` from the *measured* `dt` (never a hardcoded constant) pins the
  filter's cutoff at `1/(2*pi*tau)` regardless of scheduler jitter or differing
  per-monitor sample periods. `tau` (`tau_ms`) is the time constant: the output
  reaches ~63 % of a step after one `tau` and ~95 % after `3tau`. The first sample
  seeds the filter directly, avoiding a warm-up ramp from zero.

  The sample type is anything implementing `Controls.Linear` (the `scale/2` and
  `add/2` the convex combination needs) - a `Float`, a `Unit.Information`, a
  `Unit.Bandwidth`, etc. - so the filter is not tied to `float()`.
  """

  alias Controls.Linear

  @enforce_keys [:tau_ms]
  defstruct [:tau_ms, value: nil]

  @type t :: %__MODULE__{tau_ms: pos_integer(), value: Linear.t() | nil}

  @doc "Build a filter with time constant `tau_ms` (milliseconds)."
  @spec new(pos_integer()) :: t()
  def new(tau_ms) when is_integer(tau_ms) and tau_ms > 0 do
    %__MODULE__{tau_ms: tau_ms}
  end

  @doc """
  Fold one `sample`, taken `dt_ms` after the previous one, into the filter.

  The first sample seeds the average (its `dt_ms` is ignored).
  """
  @spec update(t(), Linear.t(), pos_integer()) :: t()
  def update(%__MODULE__{value: nil} = e, sample, _dt_ms) do
    %{e | value: sample}
  end

  def update(%__MODULE__{tau_ms: tau, value: prev} = e, sample, dt_ms)
      when is_integer(dt_ms) and dt_ms > 0 do
    alpha = 1.0 - :math.exp(-dt_ms / tau)
    %{e | value: Linear.add(Linear.scale(sample, alpha), Linear.scale(prev, 1.0 - alpha))}
  end

  @doc "The current filtered value, or `nil` before the first sample."
  @spec value(t()) :: Linear.t() | nil
  def value(%__MODULE__{value: v}), do: v
end
