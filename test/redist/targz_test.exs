defmodule Redist.TargzTest do
  @moduledoc """
  `Targz.install/3` downloads a gzipped tarball, verifies its SHA-256, and
  extracts it. The contract proven here:

    * round-trip - whatever file tree was packed extracts back byte-for-byte
      under `dest_dir` (across single-file, nested, binary, and empty-content
      archives);
    * refusal - a wrong checksum and a non-200 response each return their
      specific error tuple and never create `dest_dir`; a path-traversal
      (`../`) tar entry returns `{:error, {:unsafe_tar_entry, …}}` and
      nothing is extracted (the security-critical invariant: nothing escapes
      `dest_dir`).

  The download runs over a real localhost HTTP server, so the `Req` streaming
  path is exercised, not mocked. The transient `{:download_error, _}` branch is
  intentionally not tested: triggering it means a real network failure (slow,
  retried by Req), and the branch is a trivial pass-through of Req's error.
  """
  use ExUnit.Case, async: true

  alias Redist.Support.HttpServer
  alias Redist.Targz

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    server = HttpServer.start()
    tmp = Path.join(System.tmp_dir!(), "targz-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    # `dest` is deliberately NOT created: install/3 must create it on success and
    # never create it on failure.
    {:ok, server: server, dest: Path.join(tmp, "dest")}
  end

  @archives [
    %{name: "single file", files: %{"a.txt" => "alpha"}},
    %{
      name: "nested directories",
      files: %{"a.txt" => "alpha", "sub/b.txt" => "beta", "sub/deep/c.bin" => <<0, 1, 2, 3, 255>>}
    },
    %{name: "empty file content", files: %{"only.txt" => ""}}
  ]

  for archive <- @archives do
    @archive archive
    test "install/3 extracts #{@archive.name} faithfully", %{server: server, dest: dest} do
      bytes = targz(@archive.files)
      url = HttpServer.put_file(server, "archive.tar.gz", bytes)

      assert :ok = Targz.install(url, sha256(bytes), dest)

      for {path, contents} <- @archive.files do
        assert File.read!(Path.join(dest, path)) == contents
      end
    end
  end

  test "install/3 rejects a checksum mismatch and leaves dest untouched", %{
    server: server,
    dest: dest
  } do
    bytes = targz(%{"a.txt" => "alpha"})
    url = HttpServer.put_file(server, "archive.tar.gz", bytes)
    wrong = String.duplicate("0", 64)

    assert {:error, {:checksum_mismatch, ^wrong, actual}} = Targz.install(url, wrong, dest)
    assert actual == sha256(bytes)
    refute File.exists?(dest)
  end

  test "install/3 returns {:download_failed, 404} for a missing URL", %{
    server: server,
    dest: dest
  } do
    url = HttpServer.missing_url(server, "nope.tar.gz")
    sha = String.duplicate("0", 64)

    assert {:error, {:download_failed, 404}} = Targz.install(url, sha, dest)
    refute File.exists?(dest)
  end

  test "install/3 refuses a path-traversal tar entry", %{server: server, dest: dest} do
    bytes = evil_targz()
    url = HttpServer.put_file(server, "evil.tar.gz", bytes)

    assert {:error, {:unsafe_tar_entry, "../escape.txt"}} =
             Targz.install(url, sha256(bytes), dest)

    refute File.exists?(Path.join(Path.dirname(dest), "escape.txt"))
    assert File.ls(dest) in [{:error, :enoent}, {:ok, []}]
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp targz(files) do
    entries = Enum.map(files, fn {path, contents} -> {String.to_charlist(path), contents} end)
    build_targz(entries)
  end

  defp evil_targz, do: build_targz([{~c"../escape.txt", "pwned"}])

  defp build_targz(entries) do
    path = Path.join(System.tmp_dir!(), "build-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end
end
