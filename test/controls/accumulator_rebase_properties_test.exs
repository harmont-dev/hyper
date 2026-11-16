defmodule Controls.AccumulatorRebasePropertiesTest do
  @moduledoc """
  Laws for `Controls.Accumulator.rebase/1`, the reboot hook (#134): the
  counter's source is known to have been recreated at zero.

    * rebasing never changes what has accrued but not yet been flushed — a
      reboot between flushes loses nothing;
    * rebasing is idempotent;
    * after a rebase, the first reading accrues in full, whatever the old
      counter last read (above or below it) and whether or not a flush ran.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Controls.Accumulator
  alias Unit.Time

  defp readings, do: list_of(integer(0..1_000_000_000), min_length: 1)

  defp fold(acc, values), do: Enum.reduce(values, acc, &Accumulator.observe(&2, Time.us(&1)))

  defp total_us(acc), do: Time.as_us(Accumulator.total(acc))

  property "a rebase keeps everything accrued since the last flush" do
    check all(values <- readings()) do
      acc = fold(Accumulator.new(Time.zero()), values)
      assert total_us(Accumulator.rebase(acc)) == total_us(acc)
    end
  end

  property "rebasing twice is rebasing once" do
    check all(values <- readings(), next <- integer(0..1_000_000_000)) do
      once = values |> then(&fold(Accumulator.new(Time.zero()), &1)) |> Accumulator.rebase()
      twice = Accumulator.rebase(once)

      assert total_us(Accumulator.observe(twice, Time.us(next))) ==
               total_us(Accumulator.observe(once, Time.us(next)))
    end
  end

  property "the first reading after a rebase accrues in full" do
    check all(values <- readings(), flush? <- boolean(), next <- integer(0..1_000_000_000)) do
      acc = fold(Accumulator.new(Time.zero()), values)
      acc = if flush?, do: Accumulator.flush(acc), else: acc

      rebased = acc |> Accumulator.rebase() |> Accumulator.observe(Time.us(next))

      assert total_us(rebased) == total_us(acc) + next
    end
  end
end
