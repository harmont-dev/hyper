defmodule Unit.QuantityPropertiesTest do
  @moduledoc """
  Laws that must hold for EVERY `Unit.Quantity` value, generated across all three
  dimensions. The quantities are a signed additive group (commutative, associative,
  zero identity, subtraction is the inverse) with a total order that mirrors the
  backing integer scalar exactly. These are the contracts `Unit.Operators` and the
  `Unit.Quantity` protocol promise; the example tests only spot-check them.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  use Unit.Operators

  alias Unit.{Bandwidth, Information, Quantity, Time}

  # A bounded scalar keeps generated magnitudes readable in shrink output; Elixir
  # integers are bignums so there is no overflow concern, the bound is purely for
  # legible counterexamples.
  defp scalar, do: integer(-1_000_000..1_000_000)

  # One generator per dimension: a random scalar wrapped through the canonical
  # (bytes / bytes-per-sec / nanosecond) constructor.
  defp quantity do
    one_of([
      map(scalar(), &Information.bytes/1),
      map(scalar(), &Bandwidth.bps/1),
      map(scalar(), &Time.ns/1)
    ])
  end

  # A pair of quantities guaranteed to share a dimension (so `+`/`-`/ordering are
  # defined). Built by generating two scalars and one dimension constructor.
  defp same_dim_pair do
    gen all(
          ctor <- member_of([&Information.bytes/1, &Bandwidth.bps/1, &Time.ns/1]),
          a <- scalar(),
          b <- scalar()
        ) do
      {ctor.(a), ctor.(b)}
    end
  end

  property "with_value/value is a round-trip in both directions" do
    check all(q <- quantity(), n <- scalar()) do
      assert Quantity.value(Quantity.with_value(q, n)) == n
      assert Quantity.with_value(q, Quantity.value(q)) == q
    end
  end

  property "addition mirrors integer addition on the scalar" do
    check all({a, b} <- same_dim_pair()) do
      assert Quantity.value(a + b) == Quantity.value(a) + Quantity.value(b)
    end
  end

  property "addition is commutative and associative" do
    check all(
            ctor <- member_of([&Information.bytes/1, &Bandwidth.bps/1, &Time.ns/1]),
            x <- scalar(),
            y <- scalar(),
            z <- scalar()
          ) do
      a = ctor.(x)
      b = ctor.(y)
      c = ctor.(z)
      assert a + b == b + a
      assert a + (b + c) == a + b + c
    end
  end

  property "zero is the additive identity and subtraction is the inverse" do
    check all({a, b} <- same_dim_pair()) do
      zero = Quantity.with_value(a, 0)
      assert zero + a == a
      # `a - a` is exactly the subtraction-inverse law under test; the "always 0"
      # warning is the point here, not a mistake.
      # credo:disable-for-next-line Credo.Check.Warning.OperationOnSameValues
      assert a - a == zero
      assert a + b - b == a
    end
  end

  property "ordering matches the integer order of the backing scalars" do
    check all({a, b} <- same_dim_pair()) do
      assert a < b == Quantity.value(a) < Quantity.value(b)
      assert a <= b == Quantity.value(a) <= Quantity.value(b)
      assert a > b == Quantity.value(a) > Quantity.value(b)
      assert a <= b or b <= a
    end
  end

  property "mixing two different dimensions always raises ArgumentError" do
    pairs = [
      {Information.bytes(1), Time.ns(1)},
      {Time.ns(1), Bandwidth.bps(1)},
      {Bandwidth.bps(1), Information.bytes(1)}
    ]

    check all({a, b} <- member_of(pairs)) do
      assert_raise ArgumentError, fn -> a + b end
      assert_raise ArgumentError, fn -> a - b end
      assert_raise ArgumentError, fn -> a < b end
    end
  end
end
