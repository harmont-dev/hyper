defmodule Unit.InformationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
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

  test "sectors are 512 bytes, the kernel's block-device unit" do
    assert Information.sectors(8) == Information.bytes(4096)
  end

  property "as_sectors/sectors round-trips" do
    check all(n <- integer(-1_000_000..1_000_000)) do
      assert Information.as_sectors(Information.sectors(n)) == n
    end
  end
end
