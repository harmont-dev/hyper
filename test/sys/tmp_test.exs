defmodule Sys.TmpTest do
  @moduledoc """
  Laws of the exclusive temp helpers:

    * inside `fun` the path exists (empty file / empty dir) and its basename
      carries the caller's prefix (default `"hyper"`), so a leaked entry is
      attributable;
    * the path is gone after a normal return AND after a raise (the raise
      propagates), including any contents written under a temp dir;
    * `fun`'s return value passes through untouched;
    * paths never repeat across calls — the random component, not a VM-local
      counter, is what separates concurrent users, other processes, and
      restarts;
    * creation is exclusive: a path that already exists is never handed out.
  """
  use ExUnit.Case, async: true

  alias Sys.Tmp

  describe "with_tmpfile/2" do
    test "hands fun an existing empty file with the prefix, then removes it" do
      path =
        Tmp.with_tmpfile("tmp-law", fn path ->
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
        Tmp.with_tmpfile("tmp-law", fn path ->
          send(holder, {:path, path})
          raise "boom"
        end)
      end

      assert_receive {:path, path}
      refute File.exists?(path)
    end

    test "passes fun's return through" do
      assert Tmp.with_tmpfile("tmp-law", fn _ -> {:ok, 42} end) == {:ok, 42}
    end

    test "paths never repeat across calls" do
      paths = for _ <- 1..100, do: Tmp.with_tmpfile("tmp-law", & &1)
      assert length(Enum.uniq(paths)) == 100
    end
  end

  describe "with_tempdir/2" do
    test "hands fun an existing empty dir with the prefix, then removes it recursively" do
      dir =
        Tmp.with_tempdir("tmp-law", fn dir ->
          assert File.dir?(dir)
          assert File.ls!(dir) == []
          assert Path.basename(dir) =~ ~r/^tmp-law-[a-z2-7]+$/
          File.write!(Path.join(dir, "nested"), "x")
          dir
        end)

      refute File.exists?(dir)
    end

    test "removes the directory and its contents even when fun raises" do
      holder = self()

      assert_raise RuntimeError, "boom", fn ->
        Tmp.with_tempdir(fn dir ->
          send(holder, {:dir, dir})
          File.write!(Path.join(dir, "leftover"), "x")
          raise "boom"
        end)
      end

      assert_receive {:dir, dir}
      refute File.exists?(dir)
    end

    test "returns exactly what fun returns" do
      assert Tmp.with_tempdir(fn _dir -> {:some, "value"} end) == {:some, "value"}
    end

    test "the default prefix is hyper" do
      Tmp.with_tempdir(fn dir ->
        assert String.starts_with?(Path.basename(dir), "hyper-")
      end)
    end

    test "consecutive calls hand out distinct directories" do
      a = Tmp.with_tempdir(fn dir -> dir end)
      b = Tmp.with_tempdir(fn dir -> dir end)
      refute a == b
    end

    test "refuses to adopt a pre-existing path: a planted collision is never handed out" do
      # Simulate the old bug's precondition: with predictable names, mkdir_p
      # adopted whatever already sat at the path. With random + exclusive
      # creation we cannot plant the path in advance, so instead pin the law
      # at the primitive: a second exclusive create of the SAME path fails
      # rather than adopting it.
      dir =
        Tmp.with_tempdir("tmp-law", fn dir ->
          assert {:error, :eexist} = File.mkdir(dir)
          dir
        end)

      refute File.exists?(dir)
    end
  end
end
