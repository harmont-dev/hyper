defmodule Sys.TmpTest do
  @moduledoc """
  Contract of `Sys.Tmp.with_tempdir/2`:

    * the directory exists and is empty while `fun` runs, and is gone afterward;
    * cleanup happens even when `fun` raises — and the raise propagates;
    * the return value is exactly `fun`'s return;
    * the basename carries the prefix (default `"hyper"`), so a leaked dir is
      attributable;
    * consecutive calls never hand out the same path.
  """
  use ExUnit.Case, async: true

  alias Sys.Tmp

  test "yields an existing empty directory and removes it afterward" do
    dir =
      Tmp.with_tempdir(fn dir ->
        assert File.dir?(dir)
        assert File.ls!(dir) == []
        dir
      end)

    refute File.exists?(dir)
  end

  test "returns exactly what fun returns" do
    assert Tmp.with_tempdir(fn _dir -> {:some, "value"} end) == {:some, "value"}
  end

  test "removes the directory and its contents even when fun raises" do
    {:ok, holder} = Agent.start_link(fn -> nil end)

    assert_raise RuntimeError, "boom", fn ->
      Tmp.with_tempdir(fn dir ->
        Agent.update(holder, fn _ -> dir end)
        File.write!(Path.join(dir, "leftover"), "x")
        raise "boom"
      end)
    end

    dir = Agent.get(holder, & &1)
    assert is_binary(dir)
    refute File.exists?(dir)
  end

  test "the basename carries the given prefix" do
    Tmp.with_tempdir("mytest", fn dir ->
      assert String.starts_with?(Path.basename(dir), "mytest-")
    end)
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
end
