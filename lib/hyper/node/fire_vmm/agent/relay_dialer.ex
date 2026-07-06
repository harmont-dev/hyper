defmodule Hyper.Node.FireVMM.Agent.RelayDialer do
  @moduledoc """
  Connects to a Firecracker vsock Unix-domain socket and performs the
  host-initiated CONNECT/OK handshake, returning the open socket ready for
  use as a transparent byte pipe to the guest agent.

  Firecracker exposes its guest vsock as a host UDS. Before the connection
  becomes a transparent pipe, the host must send `"CONNECT <port>\\n"` and
  receive a line starting with `"OK "`. This module implements that handshake.
  """

  @spec dial(Path.t(), pos_integer(), non_neg_integer()) ::
          {:ok, :socket.socket()} | {:error, term()}
  def dial(vsock_uds, port, timeout_ms) do
    case :socket.open(:local, :stream) do
      {:ok, sock} -> do_dial(sock, vsock_uds, port, timeout_ms)
      {:error, _} = err -> err
    end
  end

  defp do_dial(sock, vsock_uds, port, timeout_ms) do
    with :ok <- :socket.connect(sock, %{family: :local, path: vsock_uds}, timeout_ms),
         :ok <- :socket.send(sock, "CONNECT #{port}\n"),
         {:ok, line} <- read_line(sock, timeout_ms) do
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
  defp read_line(sock, timeout_ms, acc \\ "") do
    case :socket.recv(sock, 1, timeout_ms) do
      {:ok, "\n"} -> {:ok, acc}
      {:ok, ch} -> read_line(sock, timeout_ms, acc <> ch)
      {:error, _} = err -> err
    end
  end
end
