defmodule Hyper.Node.FireVMM.Agent.RelayTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Agent.Relay

  defp tmp_path(label) do
    Path.join(System.tmp_dir!(), "relay-#{label}-#{System.unique_integer([:positive])}.sock")
  end

  setup do
    vsock_path = tmp_path("vsock")
    listen_path = tmp_path("listen")

    {:ok, fc_srv} = :socket.open(:local, :stream)
    :ok = :socket.bind(fc_srv, %{family: :local, path: vsock_path})
    :ok = :socket.listen(fc_srv, 5)

    {:ok, relay} =
      Relay.start_link(%{vm_id: "test-vm", vsock_uds: vsock_path, listen_path: listen_path})

    # Break the link so ExUnit killing the test process doesn't propagate
    # a :shutdown exit to the relay (which has trap_exit and would convert
    # it to {:stop, :shutdown}).
    true = Process.unlink(relay)
    assert File.exists?(listen_path)

    on_exit(fn ->
      if Process.alive?(relay), do: GenServer.stop(relay)
      :socket.close(fc_srv)
      File.rm(vsock_path)
      File.rm(listen_path)
    end)

    {:ok, %{fc_srv: fc_srv, relay: relay, vsock_path: vsock_path, listen_path: listen_path}}
  end

  defp start_echo_server(fc_srv) do
    spawn(fn ->
      {:ok, conn} = :socket.accept(fc_srv)
      {:ok, _} = :socket.recv(conn)
      :ok = :socket.send(conn, "OK 5\n")
      echo_loop(conn)
    end)
  end

  defp echo_loop(conn) do
    case :socket.recv(conn) do
      {:ok, data} ->
        :socket.send(conn, data)
        echo_loop(conn)

      {:error, _} ->
        :socket.close(conn)
    end
  end

  defp collect(sock, n, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_loop(sock, n, deadline, "")
  end

  defp collect_loop(_sock, 0, _deadline, acc), do: acc

  defp collect_loop(sock, need, deadline, acc) do
    left = deadline - System.monotonic_time(:millisecond)
    if left <= 0, do: raise("timeout collecting #{need} more bytes; have: #{inspect(acc)}")

    case :socket.recv(sock, need, left) do
      {:ok, data} -> collect_loop(sock, need - byte_size(data), deadline, acc <> data)
      {:error, reason} -> raise "recv error: #{inspect(reason)}"
    end
  end

  test "pipes bytes transparently from client to echo server and back",
       %{fc_srv: fc_srv, listen_path: listen_path} do
    start_echo_server(fc_srv)

    {:ok, client} = :socket.open(:local, :stream)
    :ok = :socket.connect(client, %{family: :local, path: listen_path})

    :ok = :socket.send(client, "hello world")
    assert collect(client, 11, 2_000) == "hello world"
    :socket.close(client)
  end

  test "handles fragmented sends and reassembles bytes through the relay",
       %{fc_srv: fc_srv, listen_path: listen_path} do
    start_echo_server(fc_srv)

    {:ok, client} = :socket.open(:local, :stream)
    :ok = :socket.connect(client, %{family: :local, path: listen_path})

    :ok = :socket.send(client, "hel")
    :ok = :socket.send(client, "lo!")

    assert collect(client, 6, 2_000) == "hello!"
    :socket.close(client)
  end

  test "listen_path/1 returns the path the relay is bound to",
       %{relay: relay, listen_path: listen_path} do
    assert Relay.listen_path(relay) == listen_path
  end

  test "removes the listen socket file when the relay is stopped",
       %{relay: relay, listen_path: listen_path} do
    assert File.exists?(listen_path)
    GenServer.stop(relay)
    refute File.exists?(listen_path)
  end

  test "relay stops when the acceptor exits with a non-normal reason", %{relay: relay} do
    ref = Process.monitor(relay)
    # Simulate a linked acceptor crashing with a non-:normal reason. Because
    # the GenServer traps exits, the exit signal becomes an {:EXIT, _, reason}
    # message; handle_info matches the non-:normal clause and calls
    # {:stop, reason, state}. We use a synthetic signal rather than corrupting
    # the real listen socket because triggering a non-:closed accept error
    # reliably in a test environment requires platform-specific tricks — the
    # signal path through handle_info is identical regardless of the sender PID.
    Process.exit(relay, {:accept_error, :emfile})
    assert_receive {:DOWN, ^ref, :process, ^relay, {:accept_error, :emfile}}, 1_000
  end
end
