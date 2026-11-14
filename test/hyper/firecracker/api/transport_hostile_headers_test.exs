defmodule Hyper.Firecracker.Api.TransportHostileHeadersTest do
  @moduledoc """
  The reply cap of `Hyper.Firecracker.Api.Transport` must bound everything a
  compromised, jailed Firecracker can make the node buffer, not only the body.

  Law: a reply whose header block alone exceeds the 1 MiB body cap — whether
  as many headers or as one endless header line — is never accepted as a
  successful call; it is an error, and the call returns in bounded time.
  """
  use ExUnit.Case, async: true

  alias Hyper.Firecracker.Api.Transport

  @cap Unit.Information.as_bytes(Unit.Information.mib(1))
  @header_bytes 16 * @cap

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp daemon(header_block) do
    path = Path.join(System.tmp_dir!(), "fc-hdr-#{System.unique_integer([:positive])}.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, String.to_charlist(path)}, active: false])

    server =
      spawn_link(fn ->
        {:ok, sock} = :gen_tcp.accept(listen)
        {:ok, _request} = :gen_tcp.recv(sock, 0)

        _ =
          :gen_tcp.send(sock, [
            "HTTP/1.1 200 OK\r\n",
            header_block,
            "content-type: application/json\r\ncontent-length: 2\r\nconnection: close\r\n\r\n{}"
          ])

        :gen_tcp.close(sock)
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    path
  end

  defp many_headers do
    line = "x-pad: " <> String.duplicate("a", 1016) <> "\r\n"
    List.duplicate(line, div(@header_bytes, byte_size(line)))
  end

  defp one_long_header, do: ["x-pad: ", String.duplicate("a", @header_bytes), "\r\n"]

  test "a header block past the cap is not a successful call, however it is shaped" do
    for {name, block} <- [one_long_header: one_long_header(), many_headers: many_headers()] do
      path = daemon(block)

      task =
        Task.async(fn ->
          Transport.request(%{method: :get, url: "/", opts: [socket_path: path]})
        end)

      result =
        case Task.yield(task, :timer.seconds(20)) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          nil -> :timed_out
        end

      refute match?({:ok, _}, result) or result in [:ok, :timed_out],
             "#{name}: #{div(@header_bytes, @cap)} MiB of headers -> #{inspect(result, limit: 5)}"
    end
  end
end
