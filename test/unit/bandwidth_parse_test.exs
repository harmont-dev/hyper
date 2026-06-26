defmodule Unit.BandwidthParseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Unit.Bandwidth

  test "parses each suffix" do
    assert Bandwidth.parse!("100Bps") == Bandwidth.bps(100)
    assert Bandwidth.parse!("4KiBps") == Bandwidth.kibps(4)
    assert Bandwidth.parse!("512MiBps") == Bandwidth.mibps(512)
    assert Bandwidth.parse!("1GiBps") == Bandwidth.gibps(1)
    assert Bandwidth.parse!("1 GiBps") == Bandwidth.gibps(1)
  end

  test "rejects garbage" do
    assert {:error, _} = Bandwidth.parse("1GiB")
    assert_raise ArgumentError, fn -> Bandwidth.parse!("fast") end
  end

  property "parse! inverts gibps" do
    check all n <- integer(0..1024) do
      assert Bandwidth.parse!("#{n}GiBps") == Bandwidth.gibps(n)
    end
  end
end
