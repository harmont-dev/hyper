defmodule Sys.Linux.NssPropertiesTest do
  @moduledoc """
  Round-trip and rejection laws of the pure `Nss.Passwd.from_output/1` and
  `Nss.Group.from_output/1` parsers. A well-formed line reconstructs its fields
  exactly; a line with the wrong field count or a non-integer id is rejected.
  Mirrors `Sys.Linux.SubidPropertiesTest`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Nss.{Group, Passwd}

  # A field with neither colon (field separator) nor newline (line separator);
  # `/` and `.` are allowed so home/shell look like real paths.
  defp field, do: string([?a..?z, ?A..?Z, ?0..?9, ?_, ?/, ?., ?-], max_length: 12)

  defp nonempty,
    do: string([?a..?z, ?A..?Z, ?0..?9, ?_, ?/, ?., ?-], min_length: 1, max_length: 12)

  defp id, do: integer(0..4_000_000_000)
  # Letters only, so it can never be parsed as a bare integer (malformed id case).
  defp alpha, do: string([?a..?z, ?A..?Z], min_length: 1, max_length: 8)

  describe "Passwd.from_output/1" do
    property "round-trips a well-formed passwd line into its seven fields" do
      check all(
              name <- nonempty(),
              pw <- field(),
              uid <- id(),
              gid <- id(),
              gecos <- field(),
              home <- field(),
              shell <- field()
            ) do
        line = Enum.join([name, pw, uid, gid, gecos, home, shell], ":")
        assert {:ok, [e]} = Passwd.from_output(line <> "\n")
        assert e.name == name
        assert e.password == pw
        assert e.uid == uid
        assert e.gid == gid
        assert e.gecos == gecos
        assert e.home_dir == home
        assert e.shell == shell
      end
    end

    property "parses N well-formed lines into N entries" do
      record =
        gen all(name <- nonempty(), uid <- id(), gid <- id(), home <- field(), shell <- field()) do
          Enum.join([name, "x", uid, gid, "", home, shell], ":")
        end

      check all(lines <- list_of(record, min_length: 1, max_length: 10)) do
        assert {:ok, entries} = Passwd.from_output(Enum.join(lines, "\n") <> "\n")
        assert length(entries) == length(lines)
      end
    end

    property "a non-integer uid is rejected" do
      check all(name <- nonempty(), junk <- alpha(), gid <- id()) do
        line = Enum.join([name, "x", junk, gid, "", "/h", "/sh"], ":")
        assert Passwd.from_output(line <> "\n") == {:error, :invalid_format}
      end
    end

    property "a line without exactly seven colon-fields is rejected" do
      check all(
              fields <- list_of(nonempty(), min_length: 1, max_length: 10),
              length(fields) != 7
            ) do
        assert Passwd.from_output(Enum.join(fields, ":") <> "\n") == {:error, :invalid_format}
      end
    end

    test "empty output yields an empty list" do
      assert Passwd.from_output("") == {:ok, []}
    end
  end

  describe "Group.from_output/1" do
    property "round-trips name/gid and splits the member list" do
      check all(
              name <- nonempty(),
              pw <- field(),
              gid <- id(),
              members <- list_of(nonempty(), max_length: 6)
            ) do
        line = Enum.join([name, pw, gid, Enum.join(members, ",")], ":")
        assert {:ok, [grp]} = Group.from_output(line <> "\n")
        assert grp.name == name
        assert grp.gid == gid
        assert grp.members == members
      end
    end

    property "a non-integer gid is rejected" do
      check all(name <- nonempty(), junk <- alpha(), members <- field()) do
        line = Enum.join([name, "x", junk, members], ":")
        assert Group.from_output(line <> "\n") == {:error, :invalid_format}
      end
    end

    property "fewer than four colon-fields is rejected" do
      check all(fields <- list_of(nonempty(), min_length: 1, max_length: 3)) do
        # `parse` splits with `parts: 4`; fewer than four fields can never match
        # the four-element destructure.
        assert Group.from_output(Enum.join(fields, ":") <> "\n") == {:error, :invalid_format}
      end
    end

    test "empty output yields an empty list" do
      assert Group.from_output("") == {:ok, []}
    end
  end
end
