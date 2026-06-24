defmodule Unit.InformationTest do
  use ExUnit.Case, async: true
  use Unit.Operators

  alias Unit.Information

  test "+ sums two quantities" do
    assert Information.mib(1) + Information.mib(2) == Information.mib(3)
  end

  test "- subtracts, and may go negative" do
    assert Information.mib(3) - Information.mib(1) == Information.mib(2)
    assert Information.mib(1) - Information.mib(3) == Information.mib(-2)
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

  describe "constructors and accessors" do
    test "binary-prefix constructors scale by powers of 1024" do
      assert Information.as_bytes(Information.kib(1)) == 1024
      assert Information.as_bytes(Information.mib(1)) == 1024 * 1024
      assert Information.as_bytes(Information.gib(1)) == 1024 * 1024 * 1024
      assert Information.as_bytes(Information.tib(1)) == 1024 * 1024 * 1024 * 1024
    end

    test "each prefix is 1024x the prefix below it" do
      assert Information.kib(1024) == Information.mib(1)
      assert Information.mib(1024) == Information.gib(1)
      assert Information.gib(1024) == Information.tib(1)
    end

    test "as_mib and as_gib truncate toward zero" do
      assert Information.as_mib(Information.mib(1) + Information.kib(512)) == 1
      assert Information.as_gib(Information.gib(2) + Information.mib(900)) == 2
    end
  end
end
