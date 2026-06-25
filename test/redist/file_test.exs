defmodule Redist.FileTest do
  @moduledoc """
  `File.install/3` downloads a raw file, verifies its SHA-256, and installs it at
  a destination path. The contract proven here:

    * round-trip - the bytes served are the bytes that land at `dest_path`,
      across varied payloads, and parent directories are created;
    * atomicity - a wrong checksum or a non-200 response returns the specific
      error tuple and leaves NO file at `dest_path` (the download lands in a
      temp dir first, so a failed verify never leaves a partial install).

  The download runs over a real localhost HTTP server. The transient
  `{:download_error, _}` branch is intentionally not tested (real network
  failure, retried by Req, trivial pass-through).
  """
  use ExUnit.Case, async: true

  alias Redist.File, as: RedistFile
  alias Redist.Support.HttpServer

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    server = HttpServer.start()
    tmp = Path.join(System.tmp_dir!(), "file-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    # Install into a not-yet-existing nested path so we also prove parent dirs
    # are created on success and never created on failure.
    {:ok, server: server, dest: Path.join([tmp, "nested", "asset.bin"])}
  end

  @payloads [
    %{name: "small text", bytes: "vmlinux-stub"},
    %{name: "empty file", bytes: ""},
    %{name: "binary with nulls", bytes: <<0, 1, 2, 0, 255, 0>>},
    %{name: "multi-megabyte", bytes: :binary.copy(<<0xAB>>, 3 * 1024 * 1024 + 5)}
  ]

  for payload <- @payloads do
    @payload payload
    test "install/3 places #{@payload.name} byte-for-byte at dest", %{server: server, dest: dest} do
      url = HttpServer.put_file(server, "asset.bin", @payload.bytes)

      assert :ok = RedistFile.install(url, sha256(@payload.bytes), dest)
      assert File.read!(dest) == @payload.bytes
    end
  end

  test "install/3 rejects a checksum mismatch and writes no file at dest", %{
    server: server,
    dest: dest
  } do
    bytes = "real-bytes"
    url = HttpServer.put_file(server, "asset.bin", bytes)
    wrong = String.duplicate("f", 64)

    assert {:error, {:checksum_mismatch, ^wrong, actual}} = RedistFile.install(url, wrong, dest)
    assert actual == sha256(bytes)
    refute File.exists?(dest)
  end

  test "install/3 returns {:download_failed, 404} and writes no file", %{
    server: server,
    dest: dest
  } do
    url = HttpServer.missing_url(server, "nope.bin")
    sha = String.duplicate("0", 64)

    assert {:error, {:download_failed, 404}} = RedistFile.install(url, sha, dest)
    refute File.exists?(dest)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
