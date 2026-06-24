defmodule Controls.EwmaPropertiesTest do
  @moduledoc """
  Invariants of the first-order EWMA filter that hold for any tau, any positive
  dt, and any sample sequence. Because alpha is strictly in (0, 1), the filter is
  a convex blend: its output can never overshoot past either endpoint. The first
  sample seeds the filter exactly, and a unit-quantity sample keeps its unit.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Controls.Ewma
  alias Unit.Information

  defp tau, do: integer(1..100_000)
  defp dt, do: integer(1..100_000)
  defp num, do: one_of([integer(-1_000_000..1_000_000), float(min: -1.0e6, max: 1.0e6)])

  property "the first sample seeds the value exactly, regardless of dt" do
    check all(t <- tau(), x <- num(), d <- dt()) do
      assert Ewma.value(Ewma.update(Ewma.new(t), x, d)) == x
    end
  end

  property "after one update the value stays within [min(prev, sample), max(prev, sample)]" do
    check all(t <- tau(), prev <- num(), sample <- num(), d <- dt()) do
      e = Ewma.new(t) |> Ewma.update(prev, d) |> Ewma.update(sample, d)
      v = Ewma.value(e)
      lo = min(prev, sample)
      hi = max(prev, sample)
      # Inclusive bounds with a tiny epsilon for float round-off at the endpoints.
      assert v >= lo - 1.0e-6
      assert v <= hi + 1.0e-6
    end
  end

  property "feeding the current value back in is a fixed point" do
    check all(t <- tau(), x <- num(), d <- dt()) do
      e = Ewma.new(t) |> Ewma.update(x, d) |> Ewma.update(x, d)
      assert_in_delta Ewma.value(e), x, 1.0e-6
    end
  end

  property "a unit-quantity sample is filtered and comes back as the same unit" do
    check all(
            t <- tau(),
            prev_b <- integer(0..1_000_000),
            sample_b <- integer(0..1_000_000),
            d <- dt()
          ) do
      e =
        Ewma.new(t)
        |> Ewma.update(Information.bytes(prev_b), d)
        |> Ewma.update(Information.bytes(sample_b), d)

      assert %Information{} = Ewma.value(e)
      bytes = Information.as_bytes(Ewma.value(e))
      assert bytes >= min(prev_b, sample_b)
      assert bytes <= max(prev_b, sample_b)
    end
  end
end
