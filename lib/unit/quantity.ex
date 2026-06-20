defprotocol Unit.Quantity do
  @moduledoc """
  A one-dimensional physical quantity backed by a single canonical integer
  (bytes, nanoseconds, bytes/sec, ...). Implementing this is all a unit type
  needs to get `+`, `-`, and the ordering operators from `Unit.Operators`.

  Implementations go through the type's own public constructor/accessor so the
  opaque struct stays opaque, and so per-type invariants (e.g. a byte count can
  never go negative) are enforced in one place: `with_value/2`.
  """

  @doc "The canonical scalar (e.g. bytes) backing the quantity."
  @spec value(t()) :: integer()
  def value(quantity)

  @doc """
  A quantity of the same dimension carrying scalar `n`, with the type's
  invariants applied (clamping, etc.).
  """
  @spec with_value(t(), integer()) :: t()
  def with_value(quantity, n)
end
