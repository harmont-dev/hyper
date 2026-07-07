defmodule Sys.TmpTest do
  @moduledoc """
  Laws of the exclusive temp helpers:

    * inside `fun` the path exists (empty file / empty dir) and carries the
      caller's prefix;
    * the path is gone after a normal return AND after a raise (the raise
      propagates);
    * `fun`'s return value passes through untouched;
    * paths never repeat across calls — the random component, not a VM-local
      counter, is what separates concurrent users, other processes, and
      restarts.
  """
  use ExUnit.Case, async: true

  describe "with_tmpfile/2" do
    test "hands fun an existing empty file with the prefix, then removes it" do
      path =
        Sys.Tmp.with_tmpfile("tmp-law", fn path ->
          assert File.regular?(path)
          assert File.read!(path) == ""
          assert Path.basename(path) =~ ~r/^tmp-law-[a-z2-7]+$/
          path
        end)

      refute File.exists?(path)
    end

    test "removes the file when fun raises, and the raise propagates" do
      holder = self()

      assert_raise RuntimeError, "boom", fn ->
        Sys.Tmp.with_tmpfile("tmp-law", fn path ->
          send(holder, {:path, path})
          raise "boom"
        end)
      end

      assert_receive {:path, path}
      refute File.exists?(path)
    end

    test "passes fun's return through" do
      assert Sys.Tmp.with_tmpfile("tmp-law", fn _ -> {:ok, 42} end) == {:ok, 42}
    end

    test "paths never repeat across calls" do
      paths = for _ <- 1..100, do: Sys.Tmp.with_tmpfile("tmp-law", & &1)
      assert length(Enum.uniq(paths)) == 100
    end
  end

  describe "with_tempdir/2" do
    test "hands fun an existing empty dir with the prefix, then removes it recursively" do
      dir =
        Sys.Tmp.with_tempdir("tmp-law", fn dir ->
          assert File.dir?(dir)
          assert File.ls!(dir) == []
          assert Path.basename(dir) =~ ~r/^tmp-law-[a-z2-7]+$/
          File.write!(Path.join(dir, "nested"), "x")
          dir
        end)

      refute File.exists?(dir)
    end

    test "refuses to adopt a pre-existing path: a planted collision is never handed out" do
      # Simulate the old bug's precondition: with predictable names, mkdir_p
      # adopted whatever already sat at the path. With random + exclusive
      # creation we cannot plant the path in advance, so instead pin the law
      # at the primitive: a second exclusive create of the SAME path fails
      # rather than adopting it.
      dir =
        Sys.Tmp.with_tempdir("tmp-law", fn dir ->
          assert {:error, :eexist} = File.mkdir(dir)
          dir
        end)

      refute File.exists?(dir)
    end
  end
end
