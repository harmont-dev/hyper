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

  Request frame: `<<byte_size(json)::32-unsigned-big>>` followed by UTF-8
  JSON `{argv, env?, cwd?, timeout_ms?}`. Keys with `nil` values are omitted.

  Response frame: `<<exit_code::32-signed-big>>`, then two length-prefixed
  byte fields — `<<stdout_len::32>>` + stdout bytes, `<<stderr_len::32>>`
  + stderr bytes.

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
    json = build_request_json(argv, opts)
    :gen_tcp.send(sock, [<<byte_size(json)::32>>, json])
  end

  @spec build_request_json([String.t()], keyword()) :: binary()
  defp build_request_json(argv, opts) do
    %{"argv" => argv}
    |> maybe_put("env", Keyword.get(opts, :env))
    |> maybe_put("cwd", Keyword.get(opts, :cwd))
    |> maybe_put("timeout_ms", Keyword.get(opts, :timeout_ms))
    |> Jason.encode!()
  end

  @spec maybe_put(map(), String.t(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec recv_response(:gen_tcp.socket(), non_neg_integer()) ::
          {:ok, exec_result()} | {:error, term()}
  defp recv_response(sock, timeout_ms) do
    with {:ok, <<exit_code::32-signed>>} <- recv_exactly(sock, 4, timeout_ms),
         {:ok, <<stdout_len::32>>} <- recv_exactly(sock, 4, timeout_ms),
         {:ok, stdout} <- recv_exactly(sock, stdout_len, timeout_ms),
         {:ok, <<stderr_len::32>>} <- recv_exactly(sock, 4, timeout_ms),
         {:ok, stderr} <- recv_exactly(sock, stderr_len, timeout_ms) do
      {:ok, %{exit_code: exit_code, stdout: stdout, stderr: stderr}}
    end
  end

  # Read exactly `n` bytes, looping until all arrive. `:gen_tcp.recv/3` with a
  # positive length waits until that many bytes are buffered by the OTP TCP
  # driver, so the recursive branch is a defensive backstop rather than the
  # common path — but it makes the accumulation contract explicit and protects
  # against any future refactor to a lower-level read.
  @spec recv_exactly(:gen_tcp.socket(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  defp recv_exactly(_sock, 0, _timeout_ms), do: {:ok, <<>>}

  defp recv_exactly(sock, n, timeout_ms) do
    case :gen_tcp.recv(sock, n, timeout_ms) do
      {:ok, data} when byte_size(data) == n ->
        {:ok, data}

      {:ok, partial} ->
        case recv_exactly(sock, n - byte_size(partial), timeout_ms) do
          {:ok, rest} -> {:ok, partial <> rest}
          err -> err
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Read bytes one at a time until `\n`; returns the line without the trailing
  # newline. Byte-by-byte is correct for the short (<20 byte) handshake line.
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
