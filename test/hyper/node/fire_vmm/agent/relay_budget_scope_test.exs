defmodule Hyper.Node.FireVMM.Agent.RelayBudgetScopeTest do
  @moduledoc """
  Scope of the relay's 16 MiB guest-to-host reply cap (#132):

  - it is per connection, not per relay: successive connections each get a
    fresh budget, so a VM that has answered more than the cap in total over
    several execs is still served;
  - it caps only the guest-to-host direction: the host can send the guest
    more than the cap on one connection.
  """
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Agent.Relay
  alias Unit.Information

  @cap Information.as_bytes(Information.mib(16))
  @recv_chunk Information.as_bytes(Information.mib(2))

  setup do
    vsock_path = tmp_path("vsock")
    listen_path = tmp_path("listen")

    {:ok, fc} = :socket.open(:local, :stream)
    :ok = :socket.bind(fc, %{family: :local, path: vsock_path})
    :ok = :socket.listen(fc, 16)

    start_supervised!(
      {Relay, %{vm_id: "vscope", vsock_uds: vsock_path, listen_path: listen_path}}
    )

    on_exit(fn ->
      :socket.close(fc)
      File.rm(vsock_path)
    end)

    {:ok, %{fc: fc, listen_path: listen_path}}
  end

  defp tmp_path(label),
    do: Path.join(System.tmp_dir!(), "rscope-#{label}-#{System.unique_integer([:positive])}.sock")

  defp guest(fc, fun) do
    parent = self()

    spawn_link(fn ->
      {:ok, conn} = :socket.accept(fc)
      {:ok, "CONNECT " <> _} = :socket.recv(conn)
      :ok = :socket.send(conn, "OK 5\n")
      fun.(conn, parent)
    end)
  end

  defp client(listen_path) do
    {:ok, sock} = :socket.open(:local, :stream)
    :ok = :socket.connect(sock, %{family: :local, path: listen_path})
    sock
  end

  defp drain(sock, acc \\ []) do
    case :socket.recv(sock, 0, 5_000) do
      {:ok, data} -> drain(sock, [acc | data])
      {:error, reason} -> {reason, IO.iodata_to_binary(acc)}
    end
  end

  defp recv_exactly(sock, n, acc \\ [])
  defp recv_exactly(_sock, 0, acc), do: IO.iodata_to_binary(acc)

  defp recv_exactly(sock, n, acc) do
    {:ok, data} = :socket.recv(sock, min(n, @recv_chunk), 5_000)
    recv_exactly(sock, n - byte_size(data), [acc | data])
  end

  test "each connection gets a fresh budget", %{fc: fc, listen_path: listen_path} do
    per_conn = :crypto.strong_rand_bytes(div(@cap * 3, 4))

    for _ <- 1..3 do
      guest(fc, fn conn, _ ->
        :ok = :socket.send(conn, per_conn)
        :socket.close(conn)
      end)

      assert drain(client(listen_path)) == {:closed, per_conn}
    end
  end

  test "the host can send the guest more than the cap", %{fc: fc, listen_path: listen_path} do
    upload = :crypto.strong_rand_bytes(@cap + Information.as_bytes(Information.mib(4)))

    guest(fc, fn conn, parent ->
      send(parent, {:guest_got, recv_exactly(conn, byte_size(upload))})
    end)

    :ok = :socket.send(client(listen_path), upload)
    assert_receive {:guest_got, ^upload}, 10_000
  end
end
