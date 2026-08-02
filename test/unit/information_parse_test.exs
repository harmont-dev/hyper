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

  describe "coerce!/1" do
    property "is idempotent: an already-typed quantity passes through unchanged" do
      check all(n <- integer(0..4096)) do
        size = Information.gib(n)
        assert Information.coerce!(size) == size
      end
    end

    property "agrees with parse! on every string it accepts" do
      check all(n <- integer(0..4096)) do
        assert Information.coerce!("#{n}GiB") == Information.parse!("#{n}GiB")
      end
    end

    for input <- ["", "GiB", "4 Gigs", "nope"] do
      test "rejects #{inspect(input)}" do
        assert_raise ArgumentError, fn -> Information.coerce!(unquote(input)) end
      end
    end

    test "rejects a value that is neither a quantity nor a string" do
      assert_raise ArgumentError, fn -> Information.coerce!(42) end
    end
  end
end
