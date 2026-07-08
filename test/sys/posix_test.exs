defmodule Sys.PosixTest do
  @moduledoc """
  Filesystem contracts of `Sys.Posix`, exercised against a real temporary
  filesystem (no mocks):

    * `executable?/1` is true iff the path is a regular file with *any* execute
      bit set — directories, non-executable files, and missing paths are all
      refused.
    * `ensure_writable_dir/1` accepts an existing writable directory, creates a
      missing one (with parents, idempotently), and refuses — with the specific
      posix reason — a regular file, an unwritable directory, an unwritable
      parent, and an unstatable path.
  """
  use ExUnit.Case, async: true

  alias Sys.Posix
  alias Sys.Tmp

  defp regular_file(dir, mode) do
    path = Path.join(dir, "f-#{System.unique_integer([:positive])}")
    File.write!(path, "x")
    File.chmod!(path, mode)
    path
  end

  # Root is exempt from permission checks, so permission-denial assertions
  # would spuriously succeed-to-create under uid 0. CI runs as a normal user.
  defp root?, do: System.cmd("id", ["-u"]) |> elem(0) |> String.trim() == "0"

  describe "executable?/1" do
    test "true iff the file is regular with any execute bit set" do
      cases = [
        {0o755, true},
        {0o700, true},
        {0o100, true},
        {0o010, true},
        {0o001, true},
        {0o644, false},
        {0o666, false},
        {0o000, false}
      ]

      Tmp.with_tempdir(fn dir ->
        for {mode, expected} <- cases do
          path = regular_file(dir, mode)

          assert Posix.executable?(path) == expected,
                 "mode 0o#{Integer.to_string(mode, 8)} expected #{expected}"
        end
      end)
    end

    test "a directory is not executable, even with exec bits set" do
      Tmp.with_tempdir(fn dir -> refute Posix.executable?(dir) end)
    end

    test "a missing path is not executable" do
      refute Posix.executable?("/definitely/not/here-#{System.unique_integer()}")
    end
  end

  describe "ensure_writable_dir/1" do
    test "accepts an existing writable directory" do
      Tmp.with_tempdir(fn dir -> assert Posix.ensure_writable_dir(dir) == {:ok} end)
    end

    test "creates a missing directory with parents, idempotently" do
      Tmp.with_tempdir(fn dir ->
        target = Path.join([dir, "a", "b", "c"])
        assert Posix.ensure_writable_dir(target) == {:ok}
        assert File.dir?(target)
        assert Posix.ensure_writable_dir(target) == {:ok}
      end)
    end

    test "refuses a regular file with :enotdir" do
      Tmp.with_tempdir(fn dir ->
        assert Posix.ensure_writable_dir(regular_file(dir, 0o644)) == {:error, :enotdir}
      end)
    end

    test "refuses a path under a regular file with :enotdir" do
      Tmp.with_tempdir(fn dir ->
        file = regular_file(dir, 0o644)
        assert Posix.ensure_writable_dir(Path.join(file, "child")) == {:error, :enotdir}
      end)
    end

    test "refuses an existing unwritable directory with :eacces" do
      unless root?() do
        Tmp.with_tempdir(fn dir ->
          locked = Path.join(dir, "locked")
          File.mkdir!(locked)
          File.chmod!(locked, 0o500)
          assert Posix.ensure_writable_dir(locked) == {:error, :eacces}
        end)
      end
    end

    test "surfaces the mkdir_p reason when the parent is unwritable" do
      unless root?() do
        Tmp.with_tempdir(fn dir ->
          locked = Path.join(dir, "locked")
          File.mkdir!(locked)
          File.chmod!(locked, 0o500)
          assert Posix.ensure_writable_dir(Path.join(locked, "sub")) == {:error, :eacces}
        end)
      end
    end

    test "surfaces the stat reason for an unstatable path" do
      unless root?() do
        Tmp.with_tempdir(fn dir ->
          sealed = Path.join(dir, "sealed")
          File.mkdir!(sealed)
          File.chmod!(sealed, 0o000)
          assert Posix.ensure_writable_dir(Path.join(sealed, "sub")) == {:error, :eacces}
          File.chmod!(sealed, 0o700)
        end)
      end
    end
  end
end
