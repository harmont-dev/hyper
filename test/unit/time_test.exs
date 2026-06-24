defmodule Unit.TimeTest do
  use ExUnit.Case, async: true

  alias Unit.Time

  test "constructors scale to nanoseconds" do
    assert Time.as_ns(Time.ns(1)) == 1
    assert Time.as_ns(Time.us(1)) == 1_000
    assert Time.as_ns(Time.ms(1)) == 1_000_000
    assert Time.as_ns(Time.s(1)) == 1_000_000_000
  end

  test "each unit is 1000x the unit below it" do
    assert Time.ns(1_000) == Time.us(1)
    assert Time.us(1_000) == Time.ms(1)
    assert Time.ms(1_000) == Time.s(1)
  end

  test "accessors truncate toward zero (integer division)" do
    assert Time.as_us(Time.ns(1_500)) == 1
    assert Time.as_ms(Time.ns(1_999_999)) == 1
    assert Time.as_s(Time.ms(2_500)) == 2
  end

  test "zero reads back as 0 ns" do
    assert Time.as_ns(Time.zero()) == 0
  end
end
