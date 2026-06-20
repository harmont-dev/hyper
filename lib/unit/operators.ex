defmodule Unit.Operators do
  @moduledoc """
  Operator overloading for `Unit.Quantity` types (`Unit.Information`,
  `Unit.Time`, `Unit.Bandwidth`).

  `use Unit.Operators` in a module to get unit-aware `+`, `-`, `<`, `>`, `<=`,
  and `>=`. Operands that are not unit quantities fall straight through to
  `Kernel`, so the rest of the module's integer arithmetic and comparisons are
  untouched. Equality (`==`) is left as Elixir's native struct equality, which
  already does the right thing for these single-field structs.

      defmodule Scheduler do
        use Unit.Operators

        def headroom(total, used), do: total - used        # Information - Information
        def fits?(avail, need), do: need <= avail           # Information <= Information
        def retries(n), do: n + 1                           # plain integers, via Kernel
      end

  Combining two different dimensions (`Information` + `Time`), or a quantity
  with a bare number, raises `ArgumentError` -- the whole point of the unit
  types is that those mistakes do not silently compute.
  """

  # Operators we replace from Kernel, both here (so we may define them) and in
  # any module that `use`s us.
  import Kernel, except: [+: 2, -: 2, <: 2, >: 2, <=: 2, >=: 2]

  @kernel_overrides [+: 2, -: 2, <: 2, >: 2, <=: 2, >=: 2]

  defmacro __using__(_opts) do
    quote do
      import Kernel, except: unquote(@kernel_overrides)
      import Unit.Operators
    end
  end

  @doc "Sum of two quantities of the same dimension (or `Kernel.+/2` for non-units)."
  def left + right, do: arith(left, right, &Kernel.+/2, "+")

  @doc "Difference of two quantities of the same dimension (or `Kernel.-/2` for non-units)."
  def left - right, do: arith(left, right, &Kernel.-/2, "-")

  @doc "Whether `left` is less than `right` (or `Kernel.</2` for non-units)."
  def left < right, do: order(left, right, &Kernel.</2)

  @doc "Whether `left` is greater than `right` (or `Kernel.>/2` for non-units)."
  def left > right, do: order(left, right, &Kernel.>/2)

  @doc "Whether `left` is at most `right` (or `Kernel.<=/2` for non-units)."
  def left <= right, do: order(left, right, &Kernel.<=/2)

  @doc "Whether `left` is at least `right` (or `Kernel.>=/2` for non-units)."
  def left >= right, do: order(left, right, &Kernel.>=/2)

  # Arithmetic: if either side is a unit, both must be the same unit; compute on
  # the canonical scalars and rebuild. Otherwise defer to Kernel.
  defp arith(a, b, op, sym) do
    if unit?(a) or unit?(b) do
      assert_same!(a, b, sym)
      Unit.Quantity.with_value(a, op.(Unit.Quantity.value(a), Unit.Quantity.value(b)))
    else
      op.(a, b)
    end
  end

  # Ordering: same rule, but compare the scalars and return the boolean.
  defp order(a, b, op) do
    if unit?(a) or unit?(b) do
      assert_same!(a, b, "comparison")
      op.(Unit.Quantity.value(a), Unit.Quantity.value(b))
    else
      op.(a, b)
    end
  end

  defp unit?(x), do: is_struct(x) and Unit.Quantity.impl_for(x) != nil

  defp assert_same!(a, b, sym) do
    if unit?(a) and unit?(b) and a.__struct__ == b.__struct__ do
      :ok
    else
      raise ArgumentError,
            "#{sym} requires two quantities of the same unit, got: " <>
              "#{inspect(a)} and #{inspect(b)}"
    end
  end
end
