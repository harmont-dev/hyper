defmodule Redist.Support.HttpServerTest do
  @moduledoc """
  The download tests trust this harness to serve, over real HTTP, exactly the
  bytes handed to `put_file/3`. If that round-trip ever broke, every `File`/
  `Targz` success test would pass vacuously - so the harness asserts its own
  contract: bytes written are bytes served, and an unserved path is a 404.
  """
  use ExUnit.Case, async: true

  alias Redist.Support.HttpServer

  setup do
    {:ok, server: HttpServer.start()}
  end

  test "serves the exact bytes written via put_file/3", %{server: server} do
    {:ok, _} = Application.ensure_all_started(:req)
    body = :crypto.strong_rand_bytes(4096)
    url = HttpServer.put_file(server, "blob.bin", body)

    assert %Req.Response{status: 200, body: ^body} = Req.get!(url, redirect: true)
  end

  test "returns 404 for a path that was never written", %{server: server} do
    {:ok, _} = Application.ensure_all_started(:req)
    url = HttpServer.missing_url(server, "nope.bin")

    assert %Req.Response{status: 404} = Req.get!(url, redirect: true)
  end
end
