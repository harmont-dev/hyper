defmodule Hyper.Node.FireVMM.Agent.RelayDialer do
  @moduledoc """
  Connects to a Firecracker vsock Unix-domain socket and performs the
  host-initiated CONNECT/OK handshake, returning the open socket ready for
  use as a transparent byte pipe to the guest agent.

  Firecracker exposes its guest vsock as a host UDS. Before the connection
  becomes a transparent pipe, the host must send `"CONNECT <port>\\n"` and
  receive a line starting with `"OK "`. This module implements that handshake.
  """

  @max_line_bytes 64

  @spec dial(Path.t(), pos_integer(), non_neg_integer()) ::
          {:ok, :socket.socket()} | {:error, term()}
  def dial(vsock_uds, port, timeout_ms) do
    case :socket.open(:local, :stream) do
      {:ok, sock} -> do_dial(sock, vsock_uds, port, timeout_ms)
      {:error, _} = err -> err
    end
  end

  defp do_dial(sock, vsock_uds, port, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    with :ok <- :socket.connect(sock, %{family: :local, path: vsock_uds}, timeout_ms),
         :ok <- :socket.send(sock, "CONNECT #{port}\n"),
         {:ok, line} <- read_line(sock, deadline, "") do
      if String.starts_with?(line, "OK ") do
        {:ok, sock}
      else
        _ = :socket.close(sock)
        {:error, {:vsock_no_ok, line}}
      end
    else
      {:error, _} = err ->
        _ = :socket.close(sock)
        err
    end
  end

  # Read one LF-terminated line byte-by-byte to avoid consuming any HTTP/2
  # bytes that immediately follow the handshake response on the wire.
  defp read_line(_sock, _deadline, acc) when byte_size(acc) >= @max_line_bytes,
    do: {:error, :vsock_line_too_long}

  defp read_line(sock, deadline, acc) do
    case :socket.recv(sock, 1, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, "\n"} -> {:ok, acc}
      {:ok, ch} -> read_line(sock, deadline, acc <> ch)
      {:error, _} = err -> err
    end
  end
end
