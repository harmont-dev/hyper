defmodule Sys.Linux.SubidTest do
  @moduledoc """
  File-level contract of `Sys.Linux.Subid.ranges/1`, via temp files (the
  per-line parse laws live in `subid_properties_test.exs`):

    * a file of well-formed `name:start:count` lines yields every entry
      (order-agnostic — callers scan for conflicts, they never index);
    * one malformed line *anywhere* refuses the whole file with
      `{:error, :invalid_format}` — a partial ruleset must never masquerade as
      the complete one (this file gates privilege delegation);
    * an empty file is `{:ok, []}`; a missing file surfaces `{:error, :enoent}`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Subid
  alias Sys.Linux.Subid.Spec
  alias Sys.Tmp

  defp name, do: string([?a..?z, ?0..?9, ?-, ?_], min_length: 1, max_length: 12)

  defp entry do
    gen all(n <- name(), start <- integer(0..4_294_967_295), count <- integer(1..65_536)) do
      {n, start, count}
    end
  end

  defp with_subid_file(content, fun) do
    Tmp.with_tempdir(fn dir ->
      path = Path.join(dir, "subid")
      File.write!(path, content)
      fun.(path)
    end)
  end

  property "recovers every entry of a well-formed file" do
    check all(entries <- list_of(entry(), max_length: 8)) do
      content = Enum.map_join(entries, "\n", fn {n, s, c} -> "#{n}:#{s}:#{c}" end)

      expected =
        Enum.map(entries, fn {n, s, c} -> %Spec{name: n, min_id: s, max_id: s + c} end)

      with_subid_file(content, fn path ->
        assert {:ok, specs} = Subid.ranges(path)
        assert Enum.sort(specs) == Enum.sort(expected)
      end)
    end
  end

  property "one malformed line anywhere refuses the whole file" do
    bad_lines = ["noknobs", "a:b:c", "name:12", "name:1:2:3", ":::"]

    check all(
            entries <- list_of(entry(), max_length: 6),
            bad <- member_of(bad_lines),
            pos <- integer(0..6)
          ) do
      content =
        entries
        |> Enum.map(fn {n, s, c} -> "#{n}:#{s}:#{c}" end)
        |> List.insert_at(pos, bad)
        |> Enum.join("\n")

      with_subid_file(content, fn path ->
        assert Subid.ranges(path) == {:error, :invalid_format}
      end)
    end
  end

  test "an empty file yields no ranges" do
    with_subid_file("", fn path -> assert Subid.ranges(path) == {:ok, []} end)
  end

  test "a missing file surfaces :enoent" do
    Tmp.with_tempdir(fn dir ->
      assert Subid.ranges(Path.join(dir, "nope")) == {:error, :enoent}
    end)
  end
end
