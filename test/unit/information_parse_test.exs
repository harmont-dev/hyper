defmodule Unit.InformationParseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Unit.Information

  for {input, expected} <- [
        {"100B", Information.bytes(100)},
        {"4KiB", Information.kib(4)},
        {"512MiB", Information.mib(512)},
        {"4GiB", Information.gib(4)},
        {"2TiB", Information.tib(2)},
        {"4 GiB", Information.gib(4)}
      ] do
    test "parses #{inspect(input)}" do
      assert Information.parse!(unquote(input)) == unquote(Macro.escape(expected))
    end
  end

  for input <- ["", "GiB", "4 Gigs", "4.5GiB", "nope"] do
    test "rejects #{inspect(input)}" do
      assert {:error, _} = Information.parse(unquote(input))
      assert_raise ArgumentError, fn -> Information.parse!(unquote(input)) end
    end
  end

  property "parse! inverts the gib constructor across a range" do
    check all(n <- integer(0..4096)) do
      assert Information.parse!("#{n}GiB") == Information.gib(n)
    end
  end
end
