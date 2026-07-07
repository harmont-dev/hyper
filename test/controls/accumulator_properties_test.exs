defmodule Controls.AccumulatorPropertiesTest do
  @moduledoc """
  Laws for the monotonic-counter accumulator: folding a monotone sequence
  accrues exactly `last - first`; the total is never negative for any
  sequence (resets included); a reading below the previous accrues exactly the
  new reading; observing the same reading twice adds nothing; and interleaving
  `flush/1` at arbitrary points conserves the grand total — nothing is lost or
  double-counted across flushes.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Controls.Accumulator
  alias Unit.Time

  defp readings, do: list_of(integer(0..1_000_000_000), min_length: 1)

  defp fold(acc, values) do
    Enum.reduce(values, acc, &Accumulator.observe(&2, Time.us(&1)))
  end

  property "a monotone sequence accrues exactly last - first" do
    check all(values <- readings()) do
      sorted = Enum.sort(values)
      acc = fold(Accumulator.new(Time.zero()), sorted)

      assert Time.as_us(Accumulator.total(acc)) ==
               List.last(sorted) - List.first(sorted)
    end
  end

  property "the total is never negative, resets included" do
    check all(values <- readings()) do
      acc = fold(Accumulator.new(Time.zero()), values)
      assert Time.as_us(Accumulator.total(acc)) >= 0
    end
  end

  property "a reset accrues exactly the new reading" do
    check all(first <- integer(1..1_000_000_000), salt <- integer(0..1_000_000_000)) do
      reset = rem(salt, first)

      acc =
        Accumulator.new(Time.zero())
        |> Accumulator.observe(Time.us(first))
        |> Accumulator.observe(Time.us(reset))

      assert Time.as_us(Accumulator.total(acc)) == reset
    end
  end

  property "observing the same reading twice adds nothing" do
    check all(values <- readings()) do
      doubled = Enum.flat_map(values, &[&1, &1])
      once = fold(Accumulator.new(Time.zero()), values)
      twice = fold(Accumulator.new(Time.zero()), doubled)

      assert Time.as_us(Accumulator.total(once)) == Time.as_us(Accumulator.total(twice))
    end
  end

  property "flushing at arbitrary points conserves the grand total" do
    check all(values <- readings(), flush_mask <- list_of(boolean(), length: length(values))) do
      unflushed_total =
        Accumulator.new(Time.zero()) |> fold(values) |> Accumulator.total()

      {acc, flushed_sum} =
        values
        |> Enum.zip(flush_mask)
        |> Enum.reduce({Accumulator.new(Time.zero()), 0}, fn {v, flush?}, {acc, sum} ->
          acc = Accumulator.observe(acc, Time.us(v))

          if flush? do
            {Accumulator.flush(acc), sum + Time.as_us(Accumulator.total(acc))}
          else
            {acc, sum}
          end
        end)

      assert flushed_sum + Time.as_us(Accumulator.total(acc)) ==
               Time.as_us(unflushed_total)
    end
  end
end
