defmodule Hyper.Node.FireVMM.Exec do
  @moduledoc """
  Runs one command inside a guest microVM by connecting to Firecracker's
  host-side vsock proxy (a Unix-domain socket) and speaking the guest-agent
  wire protocol.

  ## Wire protocol

  The guest agent listens on `AF_VSOCK:1024`. Firecracker exposes that vsock
  as a Unix socket (`vsock.sock`) inside the VM's chroot. Before sending the
  exec request the caller must complete Firecracker's multiplexer handshake:

      → "CONNECT 1024\\n"
      ← "OK <port>\\n"     (anything not starting with "OK " is an error)

  **Request**: a CBOR-encoded map `{argv, env?, cwd?, timeout_ms?}`. The
  client sends the bytes directly with no framing — CBOR is self-delimiting
  and the agent reads exactly one value via `ciborium::from_reader`.

  **Response**: a CBOR-encoded map `{exit_code, stdout, stderr}`. `stdout`
  and `stderr` are CBOR byte strings that unwrap from `%CBOR.Tag{tag: :bytes}`
  to raw binaries. The agent writes the value then closes the connection; the
  client reads to EOF and decodes the accumulated bytes.

  ## Readiness retry

  The guest agent is not yet listening when `run/3` is first called (the guest
  is still booting). `run/3` retries on `:econnrefused`, `:enoent`, and a
  non-`OK` handshake reply until `opts[:connect_timeout]` ms have elapsed
  (default 5 000 ms), then returns `{:error, :agent_unavailable}`.
  """

  alias Unit.Time

  @connect_retry Time.ms(100)
  @default_connect_timeout Time.s(5)
  @handshake_timeout Time.s(5)
  @default_response_timeout Time.s(30)

  @type exec_result :: %{exit_code: integer(), stdout: binary(), stderr: binary()}

  @doc """
  Runs `argv` in the guest whose vsock UDS is at `uds_path`.

  ## Options

    - `:env` — environment map forwarded to the guest process
      (`%{String.t() => String.t()}`)
    - `:cwd` — working directory inside the guest
    - `:timeout_ms` — exec-timeout hint forwarded to the guest agent
    - `:timeout` — response-read timeout on the host side, in milliseconds
      (default: #{Time.as_ms(Time.s(30))})
    - `:connect_timeout` — total window for retrying connection errors, in
      milliseconds (default: #{Time.as_ms(Time.s(5))})
  """
  @spec run(Path.t(), [String.t()], keyword()) :: {:ok, exec_result()} | {:error, term()}
  def run(uds_path, argv, opts \\ []) do
    response_ms = Keyword.get(opts, :timeout, Time.as_ms(@default_response_timeout))
    connect_ms = Keyword.get(opts, :connect_timeout, Time.as_ms(@default_connect_timeout))
    deadline = System.monotonic_time(:millisecond) + connect_ms
    run_with_retry(uds_path, argv, opts, response_ms, deadline)
  end

  @spec run_with_retry(Path.t(), [String.t()], keyword(), non_neg_integer(), integer()) ::
          {:ok, exec_result()} | {:error, term()}
  defp run_with_retry(uds_path, argv, opts, response_ms, deadline) do
    case attempt(uds_path, argv, opts, response_ms) do
      {:error, {:connect, reason}} when reason in [:econnrefused, :enoent] ->
        retry_or_fail(uds_path, argv, opts, response_ms, deadline)

      {:error, {:vsock_connect, _}} ->
        retry_or_fail(uds_path, argv, opts, response_ms, deadline)

      result ->
        result
    end
  end

  @spec retry_or_fail(Path.t(), [String.t()], keyword(), non_neg_integer(), integer()) ::
          {:ok, exec_result()} | {:error, term()}
  defp retry_or_fail(uds_path, argv, opts, response_ms, deadline) do
    if System.monotonic_time(:millisecond) >= deadline do
      {:error, :agent_unavailable}
    else
      Process.sleep(Time.as_ms(@connect_retry))
      run_with_retry(uds_path, argv, opts, response_ms, deadline)
    end
  end

  @spec attempt(Path.t(), [String.t()], keyword(), non_neg_integer()) ::
          {:ok, exec_result()} | {:error, term()}
  defp attempt(uds_path, argv, opts, response_ms) do
    case :gen_tcp.connect({:local, uds_path}, 0, [:binary, active: false, packet: :raw]) do
      {:ok, sock} ->
        result =
          with :ok <- handshake(sock),
               :ok <- send_request(sock, argv, opts) do
            recv_response(sock, response_ms)
          end

        :gen_tcp.close(sock)
        result

      {:error, reason} ->
        {:error, {:connect, reason}}
    end
  end

  @spec handshake(:gen_tcp.socket()) :: :ok | {:error, term()}
  defp handshake(sock) do
    handshake_ms = Time.as_ms(@handshake_timeout)

    with :ok <- :gen_tcp.send(sock, "CONNECT 1024\n"),
         {:ok, line} <- recv_line(sock, handshake_ms) do
      if String.starts_with?(line, "OK ") do
        :ok
      else
        {:error, {:vsock_connect, line}}
      end
    end
  end

  @spec send_request(:gen_tcp.socket(), [String.t()], keyword()) :: :ok | {:error, term()}
  defp send_request(sock, argv, opts) do
    body =
      %{"argv" => argv}
      |> maybe_put("env", Keyword.get(opts, :env))
      |> maybe_put("cwd", Keyword.get(opts, :cwd))
      |> maybe_put("timeout_ms", Keyword.get(opts, :timeout_ms))
      |> CBOR.encode()

    :gen_tcp.send(sock, body)
  end

  @spec recv_response(:gen_tcp.socket(), non_neg_integer()) ::
          {:ok, exec_result()} | {:error, term()}
  defp recv_response(sock, timeout_ms) do
    with {:ok, buffer} <- recv_until_closed(sock, timeout_ms, <<>>) do
      case CBOR.decode(buffer) do
        {:ok, %{"exit_code" => code, "stdout" => out, "stderr" => err}, _rest} ->
          with {:ok, stdout} <- unwrap_bytes(out),
               {:ok, stderr} <- unwrap_bytes(err) do
            {:ok, %{exit_code: code, stdout: stdout, stderr: stderr}}
          end

        {:ok, _other, _rest} ->
          {:error, {:cbor_decode, :unexpected_shape}}

        {:error, reason} ->
          {:error, {:cbor_decode, reason}}
      end
    end
  end

  @spec recv_until_closed(:gen_tcp.socket(), non_neg_integer(), binary()) ::
          {:ok, binary()} | {:error, term()}
  defp recv_until_closed(sock, timeout_ms, acc) do
    case :gen_tcp.recv(sock, 0, timeout_ms) do
      {:ok, data} -> recv_until_closed(sock, timeout_ms, acc <> data)
      {:error, :closed} -> {:ok, acc}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec unwrap_bytes(term()) :: {:ok, binary()} | {:error, term()}
  defp unwrap_bytes(%CBOR.Tag{tag: :bytes, value: bin}), do: {:ok, bin}
  defp unwrap_bytes(nil), do: {:ok, ""}
  defp unwrap_bytes(bin) when is_binary(bin), do: {:ok, bin}
  defp unwrap_bytes(other), do: {:error, {:bad_response, {:not_bytes, other}}}

  @spec maybe_put(map(), String.t(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec recv_line(:gen_tcp.socket(), non_neg_integer()) :: {:ok, String.t()} | {:error, term()}
  defp recv_line(sock, timeout_ms), do: recv_line(sock, timeout_ms, <<>>)

  @spec recv_line(:gen_tcp.socket(), non_neg_integer(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  defp recv_line(sock, timeout_ms, acc) do
    case :gen_tcp.recv(sock, 1, timeout_ms) do
      {:ok, "\n"} -> {:ok, acc}
      {:ok, byte} -> recv_line(sock, timeout_ms, acc <> byte)
      {:error, reason} -> {:error, reason}
    end
  end
end
