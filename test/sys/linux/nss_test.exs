defmodule Sys.Linux.NssTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Nss.{Group, Passwd}

  describe "Passwd.from_output/1" do
    test "parses a well-formed passwd line into a Spec" do
      assert {:ok, [entry]} = Passwd.from_output("root:x:0:0:root:/root:/bin/bash\n")
      assert entry.name == "root"
      assert entry.password == "x"
      assert entry.uid == 0
      assert entry.gid == 0
      assert entry.home_dir == "/root"
      assert entry.shell == "/bin/bash"
    end

    test "parses every line and ignores blank trailing lines" do
      output = "root:x:0:0:root:/root:/bin/bash\nfoo:x:1000:1000::/home/foo:/bin/sh\n\n"
      assert {:ok, entries} = Passwd.from_output(output)
      assert entries |> Enum.map(& &1.name) |> Enum.sort() == ["foo", "root"]
    end

    test "a malformed line halts the whole parse with :invalid_format" do
      output = "root:x:0:0:root:/root:/bin/bash\ngarbage\n"
      assert Passwd.from_output(output) == {:error, :invalid_format}
    end

    test "a non-integer uid is rejected" do
      assert Passwd.from_output("root:x:NaN:0:root:/root:/bin/bash\n") ==
               {:error, :invalid_format}
    end

    test "empty output yields an empty list" do
      assert Passwd.from_output("") == {:ok, []}
    end
  end

  describe "Group.from_output/1" do
    test "parses a group line and splits its members" do
      assert {:ok, [g]} = Group.from_output("wheel:x:10:alice,bob\n")
      assert g.name == "wheel"
      assert g.gid == 10
      assert g.members == ["alice", "bob"]
    end

    test "an empty member field yields an empty member list" do
      assert {:ok, [g]} = Group.from_output("nogroup:x:65534:\n")
      assert g.members == []
    end

    test "a line with too few fields is rejected" do
      assert Group.from_output("wheel:x:10\n") == {:error, :invalid_format}
    end

    test "a non-integer gid is rejected" do
      assert Group.from_output("wheel:x:xx:alice\n") == {:error, :invalid_format}
    end

    test "empty output yields an empty list" do
      assert Group.from_output("") == {:ok, []}
    end
  end
end
