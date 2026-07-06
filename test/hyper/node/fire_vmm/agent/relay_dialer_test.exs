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

  test "sends CONNECT <port> and returns ok when server replies OK", %{path: path, srv: srv} do
    spawn(fn ->
      {:ok, conn} = :socket.accept(srv)
      {:ok, _} = :socket.recv(conn)
      :ok = :socket.send(conn, "OK 5\n")
      Process.sleep(:infinity)
    end)

    assert {:ok, _sock} = RelayDialer.dial(path, 1024, 2_000)
  end

  test "returns error when server closes without replying OK", %{path: path, srv: srv} do
    spawn(fn ->
      {:ok, conn} = :socket.accept(srv)
      :socket.close(conn)
    end)

    assert {:error, _} = RelayDialer.dial(path, 1024, 2_000)
  end

  test "returns error when server replies non-OK line", %{path: path, srv: srv} do
    spawn(fn ->
      {:ok, conn} = :socket.accept(srv)
      {:ok, _} = :socket.recv(conn)
      :ok = :socket.send(conn, "ERR refused\n")
      Process.sleep(:infinity)
    end)

    assert {:error, {:vsock_no_ok, "ERR refused"}} = RelayDialer.dial(path, 1024, 2_000)
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
