defmodule Hyper.Node.ReclaimTest do
  @moduledoc """
  Tests for `Hyper.Node.Reclaim.reclaim_sockets/0`.

  Invariants exercised:

  - Files matching `grpc-*.sock` in `socket_dir` are removed.
  - Files that do not match (wrong prefix, wrong suffix, both wrong) are left
    untouched. A too-broad implementation would delete unrelated sockets or
    control files sharing the directory.
  - `socket_dir` is created if absent (safe on a fresh node with no sockets yet).

  `async: false` because `Hyper.Cfg.Toml.put_cache/1` writes to `:persistent_term`,
  which is process-global state.
  """

  use ExUnit.Case, async: false

  alias Hyper.Node.Reclaim

  setup do
    original = Hyper.Cfg.Toml.reload()

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hyper-reclaim-#{System.unique_integer([:positive])}"
      )

    socket_dir = Path.join(tmp, "socks")
    File.mkdir_p!(socket_dir)
    Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))

    on_exit(fn ->
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf!(tmp)
    end)

    {:ok, socket_dir: socket_dir}
  end

  test "removes grpc-*.sock files and leaves unrelated files intact", %{socket_dir: dir} do
    grpc_a = Path.join(dir, "grpc-vabc123.sock")
    grpc_b = Path.join(dir, "grpc-vdef456.sock")
    keep_txt = Path.join(dir, "keep.txt")
    wrong_suffix = Path.join(dir, "grpc-x.other")

    File.write!(grpc_a, "")
    File.write!(grpc_b, "")
    File.write!(keep_txt, "keep this")
    File.write!(wrong_suffix, "not a sock")

    Reclaim.reclaim_sockets()

    refute File.exists?(grpc_a), "stale grpc socket should be removed"
    refute File.exists?(grpc_b), "stale grpc socket should be removed"
    assert File.exists?(keep_txt), "unrelated file must not be removed"
    assert File.exists?(wrong_suffix), "wrong-suffix file must not be removed"
  end

  test "creates socket_dir if it does not exist" do
    new_dir =
      Path.join(
        System.tmp_dir!(),
        "hyper-reclaim-fresh-#{System.unique_integer([:positive])}"
      )

    new_socket_dir = Path.join(new_dir, "socks")
    Hyper.Cfg.Toml.put_cache(%{"work_dir" => new_dir})

    on_exit(fn -> File.rm_rf!(new_dir) end)

    refute File.exists?(new_socket_dir)
    assert Reclaim.reclaim_sockets() == :ok
    assert File.exists?(new_socket_dir)
  end
end
