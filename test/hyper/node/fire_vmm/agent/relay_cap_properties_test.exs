defmodule Hyper.Node.FireVMM.Agent.RelayCapPropertiesTest do
  @moduledoc """
  The relay's guest-to-host reply cap (#132), against a hostile guest that
  chooses how many bytes to stream and how to chunk them:

  - **never over the cap** — the client never receives more than the cap,
    however the guest chunks its stream;
  - **transparent under the cap** — a guest that stays within the cap is
    relayed byte-for-byte, and the connection stays open;
  - **cumulative, not per-chunk** — the budget is spent across the whole
    connection, so many small chunks overflow it exactly like one big one;
  - **prefix integrity** — what the client receives is always a prefix of what
    the guest sent: the cap truncates, it never reorders or corrupts;
  - **the cap is inclusive** — a guest may send exactly the cap; one byte more
    closes the connection after exactly the cap was delivered;
  - **overflow tears down both sides** — the guest-side (vsock) connection is
    closed too, so an overflowing guest cannot pin a host-side connection;
  - **overflow is per connection** — it never disturbs another connection or
    the relay's ability to accept new ones.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.FireVMM.Agent.Relay
  alias Unit.Information

  @cap Information.as_bytes(Information.mib(16))
  @quiet_ms 300

  defp tmp_path(label) do
    Path.join(System.tmp_dir!(), "relaycap-#{label}-#{System.unique_integer([:positive])}.sock")
  end

  setup do
    vsock_path = tmp_path("vsock")
    listen_path = tmp_path("listen")

    {:ok, fc} = :socket.open(:local, :stream)
    :ok = :socket.bind(fc, %{family: :local, path: vsock_path})
    :ok = :socket.listen(fc, 16)

    {:ok, relay} =
      Relay.start_link(%{vm_id: "vcap", vsock_uds: vsock_path, listen_path: listen_path})

    true = Process.unlink(relay)

    on_exit(fn ->
      if Process.alive?(relay), do: GenServer.stop(relay)
      :socket.close(fc)
      File.rm(vsock_path)
      File.rm(listen_path)
    end)

    %{fc: fc, listen_path: listen_path}
  end

  defp guest(fc, script) do
    test = self()

    spawn(fn ->
      {:ok, conn} = :socket.accept(fc)
      {:ok, "CONNECT " <> _} = :socket.recv(conn, 0, 2_000)
      :ok = :socket.send(conn, "OK 5\n")
      script.(conn)
      send(test, {:guest_sees, guest_fate(conn)})
    end)
  end

  defp guest_fate(conn) do
    case :socket.recv(conn, 0, 3_000) do
      {:ok, _} -> guest_fate(conn)
      {:error, reason} -> reason
    end
  end

  defp connect(listen_path) do
    {:ok, client} = :socket.open(:local, :stream)
    :ok = :socket.connect(client, %{family: :local, path: listen_path})
    client
  end

  defp drain(sock, acc) do
    case :socket.recv(sock, 0, @quiet_ms) do
      {:ok, data} -> drain(sock, [acc | data])
      {:error, :closed} -> {:closed, IO.iodata_to_binary(acc)}
      {:error, :timeout} -> {:open, IO.iodata_to_binary(acc)}
    end
  end

  defp payload(total, seed) do
    _ = :rand.seed(:exsss, seed)
    :rand.bytes(total)
  end

  defp chunked(bin, sizes), do: chunked(bin, sizes, sizes)

  defp chunked(<<>>, _sizes, _all), do: []
  defp chunked(bin, [], all), do: chunked(bin, all, all)

  defp chunked(bin, [n | sizes], all) do
    take = min(n, byte_size(bin))
    <<chunk::binary-size(^take), rest::binary>> = bin
    [chunk | chunked(rest, sizes, all)]
  end

  defp send_chunks(conn, chunks), do: Enum.reduce_while(chunks, :ok, &send_chunk(conn, &1, &2))

  defp send_chunk(conn, chunk, :ok) do
    case :socket.send(conn, chunk) do
      :ok -> {:cont, :ok}
      {:error, _} -> {:halt, :refused}
    end
  end

  property "the client gets a prefix of the guest's stream, never more than the cap",
           %{fc: fc, listen_path: listen_path} do
    check all(
            total <-
              one_of([
                integer(0..65_536),
                integer((@cap - Information.as_bytes(Information.mib(1)))..@cap),
                integer((@cap + 1)..(@cap + Information.as_bytes(Information.mib(2))))
              ]),
            sizes <-
              list_of(integer(512..Information.as_bytes(Information.mib(4))), min_length: 1),
            seed <- {integer(1..1_000_000), integer(1..1_000_000), integer(1..1_000_000)},
            max_runs: 12
          ) do
      sent = payload(total, seed)
      chunks = chunked(sent, sizes)
      guest(fc, fn conn -> send_chunks(conn, chunks) end)
      client = connect(listen_path)

      {fate, got} = drain(client, [])
      :socket.close(client)

      assert byte_size(got) <= @cap, "relayed #{byte_size(got)}B past the #{@cap}B cap"
      assert got == binary_part(sent, 0, byte_size(got)), "received bytes are not a prefix"

      if total <= @cap do
        assert {fate, byte_size(got)} == {:open, total}
      else
        assert fate == :closed, "#{total}B guest stream left the connection open"
      end
    end
  end

  test "many small chunks overflow the cap the same as one big chunk",
       %{fc: fc, listen_path: listen_path} do
    chunk = :binary.copy(<<7>>, 4_096)
    n = div(@cap, 4_096) + 1

    guest(fc, fn conn -> send_chunks(conn, List.duplicate(chunk, n)) end)
    client = connect(listen_path)

    assert {:closed, got} = drain(client, [])
    assert byte_size(got) <= @cap
  end

  test "exactly the cap is delivered and kept open; the next byte closes after the cap",
       %{fc: fc, listen_path: listen_path} do
    guest =
      guest(fc, fn conn ->
        :ok = :socket.send(conn, :binary.copy(<<1>>, @cap))

        receive do
          :one_more -> :ok = :socket.send(conn, <<2>>)
        end
      end)

    client = connect(listen_path)
    assert {:open, got} = drain(client, [])
    assert byte_size(got) == @cap

    send(guest, :one_more)
    assert {:closed, ""} = drain(client, [])
    assert_receive {:guest_sees, :closed}, 5_000
  end

  test "overflow closes the guest-side connection, not just the client's",
       %{fc: fc, listen_path: listen_path} do
    guest(fc, fn conn -> send_chunks(conn, [:binary.copy(<<3>>, @cap + 1)]) end)
    client = connect(listen_path)

    assert {:closed, got} = drain(client, [])
    assert byte_size(got) <= @cap
    assert_receive {:guest_sees, :closed}, 5_000
  end

  test "one connection overflowing leaves a concurrent connection and the relay serving",
       %{fc: fc, listen_path: listen_path} do
    guest(fc, &echo/1)
    calm = connect(listen_path)
    assert ping(calm, "before")

    guest(fc, fn conn -> send_chunks(conn, [:binary.copy(<<4>>, @cap + 1)]) end)
    flood = connect(listen_path)
    assert {:closed, _} = drain(flood, [])

    assert ping(calm, "after")
    guest(fc, &echo/1)
    assert ping(connect(listen_path), "new")
  end

  defp echo(conn) do
    case :socket.recv(conn, 0, 10_000) do
      {:ok, data} ->
        :ok = :socket.send(conn, data)
        echo(conn)

      {:error, _} ->
        :ok
    end
  end

  defp ping(sock, msg) do
    :ok = :socket.send(sock, msg)
    :socket.recv(sock, byte_size(msg), 2_000) == {:ok, msg}
  end
end
