defprotocol Unit.Quantity do
  @moduledoc """
  A one-dimensional physical quantity backed by a single canonical integer
  (bytes, nanoseconds, bytes/sec, ...). Implementing this is all a unit type
  needs to get `+`, `-`, and the ordering operators from `Unit.Operators`.

  Implementations go through the type's own public constructor/accessor, so the
  opaque struct is read and rebuilt without ever being poked from the outside.
  Quantities are signed: subtraction may legitimately yield a negative value (a
  deficit), and nothing clamps it.
  """

  @doc "The canonical scalar (e.g. bytes) backing the quantity."
  @spec value(t()) :: integer()
  def value(quantity)

  @doc """
  A quantity of the same dimension as `quantity`, carrying scalar `n`.

  `Unit.Operators` calls this to rebuild a result through the type's own public
  constructor, so the opaque struct is never poked from the outside. `quantity`
  only selects the implementation (the protocol dispatches on it); its scalar is
  unused.
  """
  @spec with_value(t(), integer()) :: t()
  def with_value(quantity, n)
end
