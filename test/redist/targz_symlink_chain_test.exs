defmodule Redist.TargzSymlinkChainTest do
  @moduledoc """
  `Redist.Targz.install/3` against an archive whose symlinks are each
  individually "inside" `dest_dir` but chain to escape it (`s -> .`,
  `t -> s/..`), followed by an entry written through the chain.

  Law: such an archive is refused with an error and nothing lands outside
  `dest_dir` — and the refusal comes in bounded time, because the install
  runs in the caller with no timeout of its own.
  """
  use ExUnit.Case, async: true

  alias Redist.Support.HttpServer
  alias Redist.Targz

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    tmp = Path.join(System.tmp_dir!(), "targz-chain-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, server: HttpServer.start(), tmp: tmp}
  end

  defp chained_archive(tmp) do
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    File.ln_s!(".", Path.join(src, "s"))
    File.ln_s!("s/..", Path.join(src, "t"))

    archive = Path.join(tmp, "chain.tar.gz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(archive), [:write, :compressed])
    :ok = :erl_tar.add(tar, String.to_charlist(Path.join(src, "s")), ~c"s", [])
    :ok = :erl_tar.add(tar, String.to_charlist(Path.join(src, "t")), ~c"t", [])
    :ok = :erl_tar.add(tar, "pwned", ~c"t/escape.txt", [])
    :ok = :erl_tar.close(tar)
    File.read!(archive)
  end

  test "a symlink chain out of dest_dir is refused promptly and writes nothing outside", %{
    server: server,
    tmp: tmp
  } do
    bytes = chained_archive(tmp)
    url = HttpServer.put_file(server, "chain.tar.gz", bytes)
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    root = Path.join(tmp, "root")
    dest = Path.join(root, "dest")

    task = Task.async(fn -> Targz.install(url, sha, dest) end)
    result = Task.yield(task, :timer.seconds(10)) || Task.shutdown(task, :brutal_kill)

    refute File.exists?(Path.join(root, "escape.txt"))

    assert match?({:ok, {:error, _}}, result),
           "install/3 -> #{inspect(result)} (nil: still running after 10s)"
  end
end
