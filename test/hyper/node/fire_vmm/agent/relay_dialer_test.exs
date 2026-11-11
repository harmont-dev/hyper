defmodule Hyper.Node.FireVMM.Agent.RelayDialerTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Agent.RelayDialer

  setup do
    path =
      Path.join(System.tmp_dir!(), "fc-dialer-#{System.unique_integer([:positive])}.sock")

    {:ok, srv} = :socket.open(:local, :stream)
    :ok = :socket.bind(srv, %{family: :local, path: path})
    :ok = :socket.listen(srv, 1)

    on_exit(fn ->
      :socket.close(srv)
      File.rm(path)
    end)

    {:ok, %{path: path, srv: srv}}
  end

  @dial_timeout_ms 300

  test "the handshake reply decides the dial within one deadline", %{path: path, srv: srv} do
    rows = [
      {"OK line", fn conn -> :socket.send(conn, "OK 5\n") end, &match?({:ok, _}, &1)},
      {"non-OK line", fn conn -> :socket.send(conn, "ERR refused\n") end,
       &(&1 == {:error, {:vsock_no_ok, "ERR refused"}})},
      {"overlong line", fn conn -> :socket.send(conn, String.duplicate("O", 4_096)) end,
       &(&1 == {:error, :vsock_line_too_long})},
      {"trickled line", &trickle/1, &(&1 == {:error, :timeout})},
      {"close without reply", &:socket.close/1, &match?({:error, _}, &1)}
    ]

    for {label, reply, expected?} <- rows do
      spawn(fn ->
        {:ok, conn} = :socket.accept(srv)
        {:ok, _} = :socket.recv(conn)
        _ = reply.(conn)
        Process.sleep(:infinity)
      end)

      {elapsed_us, result} = :timer.tc(fn -> RelayDialer.dial(path, 1024, @dial_timeout_ms) end)

      assert expected?.(result), "#{label}: #{inspect(result)}"
      assert elapsed_us < (@dial_timeout_ms + 500) * 1_000, "#{label} took #{elapsed_us}us"
    end
  end

  defp trickle(conn) do
    case :socket.send(conn, "O") do
      :ok ->
        Process.sleep(20)
        trickle(conn)

      {:error, _} ->
        :ok
    end
  end

  test "does not swallow bytes that immediately follow the OK line", %{path: path, srv: srv} do
    spawn(fn ->
      {:ok, conn} = :socket.accept(srv)
      {:ok, _} = :socket.recv(conn)
      # Write the OK handshake line AND the first HTTP/2-like bytes in a single
      # send. A bulk recv (e.g. recv(sock, 1024)) would consume "HELLO_H2_BYTES"
      # as part of the handshake; the byte-by-byte read must stop at the \n.
      :ok = :socket.send(conn, "OK 5\nHELLO_H2_BYTES")
      Process.sleep(:infinity)
    end)

    {:ok, sock} = RelayDialer.dial(path, 1024, 2_000)
    # The bytes after \n must be intact on the socket, readable by the caller.
    assert {:ok, "HELLO_H2_BYTES"} = :socket.recv(sock, 14, 2_000)
  end
end
