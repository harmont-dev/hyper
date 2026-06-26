defmodule Unit.TimeParseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Unit.Time

  test "parses each suffix" do
    assert Time.parse!("500ns") == Time.ns(500)
    assert Time.parse!("100us") == Time.us(100)
    assert Time.parse!("100ms") == Time.ms(100)
    assert Time.parse!("60s") == Time.s(60)
    assert Time.parse!("30m") == Time.s(30 * 60)
    assert Time.parse!("1h") == Time.s(3600)
    assert Time.parse!("1 h") == Time.s(3600)
  end

  test "rejects garbage" do
    assert {:error, _} = Time.parse("5")
    assert {:error, _} = Time.parse("5 secs")
    assert_raise ArgumentError, fn -> Time.parse!("soon") end
  end

  property "parse! inverts s" do
    check all(n <- integer(0..100_000)) do
      assert Time.parse!("#{n}s") == Time.s(n)
    end
  end
end
