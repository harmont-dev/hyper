defmodule Hyper.GuestService.HeaderPropertiesTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.GuestService.Header

  @charset Enum.concat([?a..?z, ?0..?9, [?_, ?-]])

  defp name(max \\ 255) do
    gen all(len <- integer(1..max), chars <- list_of(member_of(@charset), length: len)) do
      List.to_string(chars)
    end
  end

  defp foreign_byte do
    member_of(Enum.to_list(1..255) -- @charset)
  end

  property "a valid name and NUL parse to the name, leaving the rest untouched" do
    check all(name <- name(), rest <- binary()) do
      assert Header.parse(name <> <<0>> <> rest) == {:ok, name, rest}
    end
  end

  property "every strict prefix of a valid header is :more" do
    check all(name <- name(), cut <- integer(0..byte_size(name))) do
      assert Header.parse(binary_part(name, 0, cut)) == :more
    end
  end

  property "256 bytes without a NUL is :too_long" do
    check all(
            len <- integer(256..600),
            bytes <- list_of(integer(1..255), length: len),
            tail <- binary()
          ) do
      assert Header.parse(:erlang.list_to_binary(bytes) <> tail) == {:error, :too_long}
    end
  end

  property "a NUL past the 255th name byte is :too_long" do
    check all(extra <- integer(0..64)) do
      assert Header.parse(String.duplicate("a", 256 + extra) <> <<0>>) == {:error, :too_long}
    end
  end

  property "a foreign byte in the name is :bad_name, with or without the NUL yet" do
    check all(
            before <- name(127),
            byte <- foreign_byte(),
            terminated <- boolean()
          ) do
      header = before <> <<byte>>
      header = if terminated, do: header <> <<0>>, else: header
      assert Header.parse(header) == {:error, :bad_name}
    end
  end

  test "an empty name is :bad_name" do
    assert Header.parse(<<0, "admin">>) == {:error, :bad_name}
  end
end
