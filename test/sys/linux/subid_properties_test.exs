defmodule Sys.Linux.SubidPropertiesTest do
  @moduledoc """
  Invariants of `Subid.parse/1`: a well-formed `name:start:count` round-trips to
  a range whose width is exactly `count` (max_id = start + count), and malformed
  lines (wrong field count, non-integer fields) are rejected.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Subid

  # A subuid name: no colon (the field separator), non-empty.
  defp name, do: string([?a..?z, ?A..?Z, ?0..?9, ?_, ?-], min_length: 1, max_length: 12)
  defp nonneg, do: integer(0..4_000_000_000)
  # A token guaranteed NOT to be a bare integer (letters only), for malformed cases.
  defp alpha, do: string([?a..?z, ?A..?Z], min_length: 1, max_length: 8)

  property "round-trips name/start and makes max_id = start + count" do
    check all(n <- name(), start <- nonneg(), count <- nonneg()) do
      assert {:ok, spec} = Subid.parse("#{n}:#{start}:#{count}")
      assert spec.name == n
      assert spec.min_id == start
      assert spec.max_id == start + count
      assert spec.max_id - spec.min_id == count
      assert spec.max_id >= spec.min_id
    end
  end

  property "a line without exactly three colon fields is invalid" do
    check all(
            fields <- list_of(name(), min_length: 0, max_length: 5),
            fields != [] and length(fields) != 3
          ) do
      assert Subid.parse(Enum.join(fields, ":")) == {:error, :invalid_format}
    end
  end

  property "non-integer start or count is rejected" do
    check all(n <- name(), junk <- alpha(), start <- nonneg()) do
      # `junk` is letters only, so it can never be a bare integer string.
      assert Subid.parse("#{n}:#{junk}:5") == {:error, :invalid_format}
      assert Subid.parse("#{n}:#{start}:#{junk}") == {:error, :invalid_format}
    end
  end
end
