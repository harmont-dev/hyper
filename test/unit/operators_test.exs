defmodule Unit.OperatorsTest do
  use ExUnit.Case, async: true
  use Unit.Operators

  alias Unit.Bandwidth
  alias Unit.Information
  alias Unit.Time

  test "arithmetic works across every unit dimension" do
    assert Time.ms(20) + Time.ms(5) == Time.ms(25)
    assert Bandwidth.mibps(3) - Bandwidth.mibps(1) == Bandwidth.mibps(2)
    assert Information.gib(1) + Information.gib(1) == Information.gib(2)
  end

  test "subtraction may go negative in every dimension" do
    assert Time.ms(1) - Time.ms(3) == Time.ns(-2_000_000)
    assert Information.mib(1) - Information.mib(3) == Information.mib(-2)
    assert Bandwidth.mibps(1) - Bandwidth.mibps(3) == Bandwidth.mibps(-2)
  end

  test "ordering operators compare within a dimension" do
    assert Time.ms(10) < Time.ms(20)
    assert Bandwidth.mibps(5) >= Bandwidth.mibps(5)
    refute Information.gib(2) > Information.gib(2)
  end

  test "zero is each dimension's additive identity" do
    assert Time.zero() + Time.ms(7) == Time.ms(7)
    assert Bandwidth.zero() + Bandwidth.mibps(7) == Bandwidth.mibps(7)
    assert Information.zero() + Information.mib(7) == Information.mib(7)
  end

  test "non-unit operands fall through to Kernel" do
    assert 2 + 3 == 5
    assert 10 - 4 == 6
    assert 1 < 2
    assert 5 >= 5
  end

  test "mixing dimensions raises" do
    assert_raise ArgumentError, fn -> Information.mib(1) + Time.ms(1) end
    assert_raise ArgumentError, fn -> Time.ms(1) < Bandwidth.mibps(1) end
  end

  test "mixing a quantity with a bare number raises" do
    assert_raise ArgumentError, fn -> Information.mib(1) + 5 end
  end
end
