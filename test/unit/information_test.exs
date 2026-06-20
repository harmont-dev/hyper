defmodule Unit.InformationTest do
  use ExUnit.Case, async: true
  use Unit.Operators

  alias Unit.Information

  test "+ sums two quantities" do
    assert Information.mib(1) + Information.mib(2) == Information.mib(3)
  end

  test "- subtracts and clamps at zero (bytes are non-negative)" do
    assert Information.mib(3) - Information.mib(1) == Information.mib(2)
    assert Information.mib(1) - Information.mib(3) == Information.zero()
  end

  test "ordering operators compare quantities" do
    assert Information.mib(1) < Information.mib(2)
    assert Information.mib(2) <= Information.mib(2)
    assert Information.mib(3) > Information.mib(2)
    assert Information.mib(2) >= Information.mib(2)
    refute Information.mib(2) < Information.mib(2)
  end

  test "zero is the additive identity" do
    assert Information.zero() + Information.gib(1) == Information.gib(1)
  end
end
