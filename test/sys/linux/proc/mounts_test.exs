defmodule Sys.Linux.Proc.MountsTest do
  @moduledoc """
  Contract of `/proc/mounts` reading:

    * `parse/1` keeps exactly the well-formed fstab lines, in file order, and
      silently skips malformed ones — `/proc/mounts` is kernel-generated, so a
      malformed line is noise, not an error;
    * `list/0` on a live Linux host always includes the root mount `/`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Fstab
  alias Sys.Linux.Proc.Mounts

  defp token, do: string([?a..?z, ?0..?9, ?/, ?-, ?_, ?.], min_length: 1, max_length: 12)

  defp valid_line do
    gen all(device <- token(), mp <- token(), fs <- token(), opt <- token()) do
      {:valid, "#{device} #{mp} #{fs} #{opt} 0 0"}
    end
  end

  # Lines Fstab.parse refuses: blank-ish, comments, fewer than four fields.
  defp garbage_line do
    ["", "   ", "# a comment", "only three fields"]
    |> Enum.map(&constant({:garbage, &1}))
    |> one_of()
  end

  property "keeps exactly the well-formed lines, in order, skipping garbage" do
    check all(lines <- list_of(one_of([valid_line(), garbage_line()]), max_length: 12)) do
      content = Enum.map_join(lines, "\n", fn {_kind, line} -> line end)

      expected =
        for {:valid, line} <- lines do
          {:ok, spec} = Fstab.parse(line)
          spec
        end

      assert Mounts.parse(content) == expected
    end
  end

  test "the live /proc/mounts includes the root mount" do
    assert {:ok, specs} = Mounts.list()
    assert Enum.any?(specs, &(&1.mount_point == "/"))
  end
end
