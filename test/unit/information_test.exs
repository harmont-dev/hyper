defmodule Unit.InformationTest do
  use ExUnit.Case, async: true

  alias Unit.Information

  test "add sums two quantities" do
    assert Information.add(Information.mib(1), Information.mib(2)) == Information.mib(3)
  end

  test "sub subtracts and clamps at zero" do
    assert Information.sub(Information.mib(3), Information.mib(1)) == Information.mib(2)
    assert Information.sub(Information.mib(1), Information.mib(3)) == Information.zero()
  end

  test "compare orders quantities" do
    assert Information.compare(Information.mib(1), Information.mib(2)) == :lt
    assert Information.compare(Information.mib(2), Information.mib(2)) == :eq
    assert Information.compare(Information.mib(3), Information.mib(2)) == :gt
  end

  test "zero is the additive identity" do
    assert Information.add(Information.zero(), Information.gib(1)) == Information.gib(1)
  end
end
