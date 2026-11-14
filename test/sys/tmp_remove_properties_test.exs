defmodule Sys.TmpRemovePropertiesTest do
  @moduledoc """
  Cleanup laws of `Sys.Tmp.with_tempdir/2` against trees an unpacked image can
  leave behind (nested dirs of any mode down to 0000, files of any mode, and
  symlinks pointing out of the tree at dirs and files with restrictive modes):

    * the temp dir is always gone afterwards, on return and on raise;
    * nothing reachable only through a symlink is removed, and no symlink
      target outside the tree has its mode changed (cleanup makes the tree
      traversable without ever chmodding through a link);
    * if `fun` swaps the temp dir itself for a symlink to an outside dir,
      cleanup removes the link and leaves the outside dir and its contents
      as they were.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Sys.Tmp

  @moduletag :tmp_dir

  @dir_modes [0o000, 0o100, 0o200, 0o300, 0o400, 0o500, 0o555, 0o700]
  @file_modes [0o000, 0o400, 0o644, 0o4755]

  defp tree do
    leaf =
      StreamData.one_of([
        StreamData.tuple({StreamData.constant(:file), StreamData.member_of(@file_modes)}),
        StreamData.member_of([{:link, :outside_dir}, {:link, :outside_file}, {:link, :dangling}])
      ])

    StreamData.tree(leaf, fn child ->
      StreamData.tuple(
        {StreamData.constant(:dir), StreamData.member_of(@dir_modes),
         StreamData.list_of(child, max_length: 3)}
      )
    end)
  end

  defp outside(tmp) do
    root = Path.join(tmp, "o#{System.unique_integer([:positive])}")
    dir = Path.join(root, "dir")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "keep"), "keep")
    file = Path.join(root, "file")
    File.write!(file, "outside")
    File.chmod!(file, 0o400)
    File.chmod!(dir, 0o500)
    %{root: root, dir: dir, file: file}
  end

  defp build!({:file, mode}, path, _out) do
    File.write!(path, "x")
    File.chmod!(path, mode)
  end

  defp build!({:link, :outside_dir}, path, out), do: File.ln_s!(out.dir, path)
  defp build!({:link, :outside_file}, path, out), do: File.ln_s!(out.file, path)
  defp build!({:link, :dangling}, path, out), do: File.ln_s!(Path.join(out.root, "nope"), path)

  defp build!({:dir, mode, children}, path, out) do
    File.mkdir!(path)

    children
    |> Enum.with_index()
    |> Enum.each(fn {child, i} -> build!(child, Path.join(path, "n#{i}"), out) end)

    File.chmod!(path, mode)
  end

  defp assert_outside_intact(out) do
    assert band(File.lstat!(out.dir).mode, 0o7777) == 0o500
    assert band(File.lstat!(out.file).mode, 0o7777) == 0o400
    assert File.read!(Path.join(out.dir, "keep")) == "keep"
    assert File.read!(out.file) == "outside"
    refute File.exists?(Path.join(out.root, "nope"))
  end

  defp release(out) do
    File.chmod!(out.dir, 0o700)
    File.chmod!(out.file, 0o600)
  end

  property "any image-shaped tree is removed and nothing behind a symlink is touched", %{
    tmp_dir: tmp
  } do
    check all(shape <- tree(), raise? <- StreamData.boolean(), max_runs: 150) do
      out = outside(tmp)

      work = fn dir ->
        build!(shape, Path.join(dir, "rootfs"), out)
        if raise?, do: raise("boom"), else: dir
      end

      dir =
        if raise? do
          holder = self()

          assert_raise RuntimeError, fn ->
            Tmp.with_tempdir("tmp-prop", fn dir ->
              send(holder, {:dir, dir})
              work.(dir)
            end)
          end

          assert_receive {:dir, dir}
          dir
        else
          Tmp.with_tempdir("tmp-prop", work)
        end

      assert {:error, :enoent} = File.lstat(dir), inspect(shape)
      assert_outside_intact(out)
      release(out)
    end
  end

  test "a temp dir swapped for a symlink to an outside dir is unlinked, not followed", %{
    tmp_dir: tmp
  } do
    out = outside(tmp)

    dir =
      Tmp.with_tempdir("tmp-prop", fn dir ->
        File.rmdir!(dir)
        File.ln_s!(out.dir, dir)
        dir
      end)

    assert {:error, :enoent} = File.lstat(dir)
    assert_outside_intact(out)
    release(out)
  end
end
