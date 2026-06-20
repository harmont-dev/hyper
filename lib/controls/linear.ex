defprotocol Controls.Linear do
  @moduledoc """
  Values that form a one-dimensional real vector space - the structure a linear
  filter needs.

  `Controls.Ewma` computes the convex combination `alpha*x + (1-alpha)*y`, which
  requires only two operations: `scale/2` (multiply a value by a real) and `add/2`
  (sum two values). Implement those for a type and it can flow through the filter
  unchanged - as a `Unit.Information`, a `Unit.Bandwidth`, a bare `Float`, etc. -
  so readings are never forced down to `float()`.

  `to_float/1` is **not** used by the filter; it projects a value to its scalar
  magnitude purely so the monitor pipeline can emit numeric `:telemetry`
  measurements.

  Note: integer-backed quantities (`Unit.Information`, `Unit.Bandwidth`) round on
  every `scale/2`, giving the filtered series a resolution floor of roughly one
  unit per `alpha`. For byte-scale metrics that floor is far below the noise and
  does not matter.
  """

  @doc "Multiply `value` by the real `factor`."
  @spec scale(t(), float()) :: t()
  def scale(value, factor)

  @doc "Add two values of the same type."
  @spec add(t(), t()) :: t()
  def add(a, b)

  @doc "Project to a scalar magnitude (for telemetry only, not the filter)."
  @spec to_float(t()) :: float()
  def to_float(value)
end

defimpl Controls.Linear, for: Float do
  def scale(value, factor), do: value * factor
  def add(a, b), do: a + b
  def to_float(value), do: value
end

defimpl Controls.Linear, for: Unit.Information do
  alias Unit.Information

  def scale(info, factor), do: Information.bytes(round(Information.as_bytes(info) * factor))
  def add(a, b), do: Information.bytes(Information.as_bytes(a) + Information.as_bytes(b))
  def to_float(info), do: Information.as_bytes(info) * 1.0
end

defimpl Controls.Linear, for: Unit.Bandwidth do
  alias Unit.Bandwidth

  def scale(bw, factor),
    do: Bandwidth.bps(round(Bandwidth.as_bytes_per_sec(bw) * factor))

  def add(a, b),
    do: Bandwidth.bps(Bandwidth.as_bytes_per_sec(a) + Bandwidth.as_bytes_per_sec(b))

  def to_float(bw), do: Bandwidth.as_bytes_per_sec(bw) * 1.0
end
