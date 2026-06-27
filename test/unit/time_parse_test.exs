defmodule Unit.TimeParseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Unit.Time

  for {input, expected} <- [
        {"500ns", Time.ns(500)},
        {"100us", Time.us(100)},
        {"100ms", Time.ms(100)},
        {"60s", Time.s(60)},
        {"30m", Time.s(30 * 60)},
        {"1h", Time.s(3600)},
        {"1 h", Time.s(3600)}
      ] do
    test "parses #{inspect(input)}" do
      assert Time.parse!(unquote(input)) == unquote(Macro.escape(expected))
    end
  end

  for input <- ["5", "5 secs", "soon", ""] do
    test "rejects #{inspect(input)}" do
      assert {:error, _} = Time.parse(unquote(input))
      assert_raise ArgumentError, fn -> Time.parse!(unquote(input)) end
    end
  end

  property "parse! inverts the s constructor across a range" do
    check all(n <- integer(0..100_000)) do
      assert Time.parse!("#{n}s") == Time.s(n)
    end
  end
end
