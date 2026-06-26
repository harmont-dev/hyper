defmodule Unit.InformationParseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Unit.Information

  test "parses each suffix to the right magnitude" do
    assert Information.parse!("100B") == Information.bytes(100)
    assert Information.parse!("4KiB") == Information.kib(4)
    assert Information.parse!("512MiB") == Information.mib(512)
    assert Information.parse!("4GiB") == Information.gib(4)
    assert Information.parse!("2TiB") == Information.tib(2)
    assert Information.parse!("4 GiB") == Information.gib(4)
  end

  test "rejects garbage" do
    assert {:error, _} = Information.parse("")
    assert {:error, _} = Information.parse("GiB")
    assert {:error, _} = Information.parse("4 Gigs")
    assert {:error, _} = Information.parse("4.5GiB")
    assert_raise ArgumentError, fn -> Information.parse!("nope") end
  end

  property "parse! inverts the gib constructor" do
    check all(n <- integer(0..4096)) do
      assert Information.parse!("#{n}GiB") == Information.gib(n)
    end
  end
end
