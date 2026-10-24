defmodule Num.IntPropertiesTest do
  @moduledoc """
  `Num.Int.parse_unsigned/1` accepts exactly the non-empty strings of ASCII
  decimal digits:

    * oracle — on any digit string it returns that string's integer value
      (`String.to_integer/1`), leading zeros included;
    * refusal — a leading `+`/`-` sign, or a single non-digit anywhere
      (whitespace, a trailing unit, a non-ASCII digit), yields `:error`, never
      a partial parse.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Num.Int

  defp digits, do: string(?0..?9, min_length: 1, max_length: 40)

  # A single codepoint that is not an ASCII digit. Uniform codepoints would
  # almost never draw a sign or whitespace — exactly what `Integer.parse/1`
  # tolerates — so those are drawn half the time.
  defp non_digit do
    one_of([
      member_of(["+", "-", " ", "\t", "\n", "_", ".", "e", "x"]),
      filter(string(:utf8, length: 1), &(not (&1 =~ ~r/\A[0-9]\z/)))
    ])
  end

  property "a digit string parses to its integer value" do
    check all(s <- digits()) do
      assert Int.parse_unsigned(s) == {:ok, String.to_integer(s)}
    end
  end

  property "a signed digit string is rejected" do
    check all(s <- digits(), sign <- member_of(["+", "-"])) do
      assert Int.parse_unsigned(sign <> s) == :error
    end
  end

  property "a non-digit anywhere in the string is rejected" do
    check all(s <- digits(), junk <- non_digit(), at <- integer(0..String.length(s))) do
      {head, tail} = String.split_at(s, at)
      assert Int.parse_unsigned(head <> junk <> tail) == :error
    end
  end

  test "the empty string is rejected" do
    assert Int.parse_unsigned("") == :error
  end
end
