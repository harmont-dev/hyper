defmodule Hyper.Node.FireVMM.Agent.RelayDialerPropertiesTest do
  @moduledoc """
  `RelayDialer.dial/3`'s handshake refusals (#132), over arbitrary reply lines
  the vsock UDS can answer `CONNECT` with:

  - **length bound** — a line whose content (before the LF) is 64 bytes or more
    is always `{:error, :vsock_line_too_long}`, whatever its bytes; a shorter
    one is never refused for length;
  - **exact acceptance** — a short line is accepted iff it starts with the
    exact bytes `"OK "`; any other short line is `{:error, {:vsock_no_ok,
    line}}` carrying the line verbatim (case, leading space, missing space and
    NUL/non-UTF-8 bytes do not pass);
  - **no over-read** — on acceptance every byte after the LF is left on the
    socket for the caller.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.FireVMM.Agent.RelayDialer

  @max_line_bytes 64

  setup do
    path = Path.join(System.tmp_dir!(), "dialprop-#{System.unique_integer([:positive])}.sock")
    {:ok, srv} = :socket.open(:local, :stream)
    :ok = :socket.bind(srv, %{family: :local, path: path})
    :ok = :socket.listen(srv, 4)

    on_exit(fn ->
      :socket.close(srv)
      File.rm(path)
    end)

    %{path: path, srv: srv}
  end

  defp answer(srv, bytes) do
    spawn_link(fn ->
      {:ok, conn} = :socket.accept(srv)
      {:ok, "CONNECT 1024\n"} = :socket.recv(conn, 0, 2_000)
      _ = :socket.send(conn, bytes)
      Process.sleep(:infinity)
    end)
  end

  defp no_lf(gen), do: map(gen, &:binary.replace(&1, "\n", "x", [:global]))

  defp line do
    one_of([
      no_lf(binary(max_length: @max_line_bytes + 8)),
      map(no_lf(binary(max_length: @max_line_bytes)), &("OK " <> &1)),
      member_of(["ok 5", " OK 5", "OK5", "OK", "OK\t5", "OK\0 5", <<"OK", 0xC3, " 5">>]),
      map(
        integer((@max_line_bytes - 2)..(@max_line_bytes + 2)),
        &("OK " <> :binary.copy("5", &1 - 3))
      )
    ])
  end

  property "a line is refused for length iff it is 64 bytes or more, else decided by its OK prefix",
           %{path: path, srv: srv} do
    check all(line <- line(), tail <- binary(max_length: 32), max_runs: 200) do
      answer(srv, line <> "\n" <> tail)
      result = RelayDialer.dial(path, 1024, 1_000)

      cond do
        byte_size(line) >= @max_line_bytes ->
          assert result == {:error, :vsock_line_too_long}

        String.starts_with?(line, "OK ") ->
          assert {:ok, sock} = result

          if tail != "" do
            assert :socket.recv(sock, byte_size(tail), 1_000) == {:ok, tail}
          end

          :socket.close(sock)

        true ->
          assert result == {:error, {:vsock_no_ok, line}}
      end
    end
  end

  property "an unterminated line of 64 bytes or more is refused without waiting for the deadline",
           %{path: path, srv: srv} do
    check all(junk <- no_lf(binary(min_length: @max_line_bytes, max_length: 4_096)), max_runs: 30) do
      answer(srv, junk)
      {us, result} = :timer.tc(fn -> RelayDialer.dial(path, 1024, 5_000) end)

      assert result == {:error, :vsock_line_too_long}
      assert us < 1_000_000, "waited #{div(us, 1_000)}ms on an already-overlong line"
    end
  end
end
