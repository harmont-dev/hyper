defmodule Redist.TargzReplaceTest do
  @moduledoc """
  `Redist.Targz.install/3` into a `dest_dir` that already holds files - the
  reinstall path `mix firecracker.install` relies on to never keep an old or
  planted binary.

  Laws:

    * the archive wins: every entry lands with the archive's bytes, whatever
      regular file previously sat at that path (stale release or plant);
    * a planted symlink at an entry path is never written through - the
      file it points at is unchanged, whether the install succeeds or refuses;
    * an archive symlink cannot be used to write outside `dest_dir`.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Redist.Support.HttpServer
  alias Redist.Targz

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    tmp = Path.join(System.tmp_dir!(), "targz-replace-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, server: HttpServer.start(), tmp: tmp}
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp targz(tmp, entries) do
    path = Path.join(tmp, "build-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp install(server, bytes, dest) do
    url = HttpServer.put_file(server, "a-#{System.unique_integer([:positive])}.tar.gz", bytes)
    Targz.install(url, sha256(bytes), dest)
  end

  property "every entry lands with the archive's bytes over whatever file was there",
           %{server: server, tmp: tmp} do
    check all(
            fresh <- binary(min_length: 1, max_length: 512),
            stale <- binary(max_length: 512),
            max_runs: 25
          ) do
      dest = Path.join(tmp, "dest-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(dest, "release"))
      File.write!(Path.join(dest, "release/firecracker"), stale)

      bytes = targz(tmp, [{~c"release/firecracker", fresh}])

      assert install(server, bytes, dest) == :ok
      assert File.read!(Path.join(dest, "release/firecracker")) == fresh
    end
  end

  test "a planted symlink at an entry path is never written through", %{
    server: server,
    tmp: tmp
  } do
    victim = Path.join(tmp, "victim")
    File.write!(victim, "operator data")
    dest = Path.join(tmp, "dest")
    File.mkdir_p!(dest)
    File.ln_s!(victim, Path.join(dest, "firecracker"))

    _ = install(server, targz(tmp, [{~c"firecracker", "archive bytes"}]), dest)

    assert File.read!(victim) == "operator data"
  end

  test "an archive symlink cannot be followed out of dest_dir", %{server: server, tmp: tmp} do
    outside = Path.join(tmp, "outside")
    File.mkdir_p!(outside)
    src = Path.join(tmp, "src")
    File.mkdir_p!(src)
    File.ln_s!(outside, Path.join(src, "link"))

    archive = Path.join(tmp, "evil.tar.gz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(archive), [:write, :compressed])
    :ok = :erl_tar.add(tar, String.to_charlist(Path.join(src, "link")), ~c"link", [])
    :ok = :erl_tar.add(tar, "pwned", ~c"link/escape.txt", [])
    :ok = :erl_tar.close(tar)

    got = install(server, File.read!(archive), Path.join(tmp, "dest"))

    assert match?({:error, _}, got)
    assert File.ls!(outside) == []
  end
end
