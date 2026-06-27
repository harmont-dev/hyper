defmodule Unit.BandwidthParseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Unit.Bandwidth

  for {input, expected} <- [
        {"100Bps", Bandwidth.bps(100)},
        {"4KiBps", Bandwidth.kibps(4)},
        {"512MiBps", Bandwidth.mibps(512)},
        {"1GiBps", Bandwidth.gibps(1)},
        {"1 GiBps", Bandwidth.gibps(1)}
      ] do
    test "parses #{inspect(input)}" do
      assert Bandwidth.parse!(unquote(input)) == unquote(Macro.escape(expected))
    end
  end

  for input <- ["1GiB", "fast", ""] do
    test "rejects #{inspect(input)}" do
      assert {:error, _} = Bandwidth.parse(unquote(input))
      assert_raise ArgumentError, fn -> Bandwidth.parse!(unquote(input)) end
    end
  end

  property "parse! inverts the gibps constructor across a range" do
    check all(n <- integer(0..1024)) do
      assert Bandwidth.parse!("#{n}GiBps") == Bandwidth.gibps(n)
    end
  end
end
