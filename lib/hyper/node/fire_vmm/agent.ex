defmodule Hyper.Node.FireVMM.Agent do
  @moduledoc """
  gRPC client to the in-guest agent, dialed through the per-VM relay UDS.

  `relay_socket_path/1` is the single source of truth for the host-side
  Unix-domain socket the relay listens on. The relay derives its own listen
  path from it, so both sides agree without a process-registry lookup.
  """

  alias Hyper.Agent.V1.{ExecRequest, ExecResponse, GuestAgent}

  # GRPC.Status codes stored as module attributes so they can be used in
  # guard-equivalent pattern matches without calling functions at match time.
  @unavailable GRPC.Status.unavailable()
  @deadline_exceeded GRPC.Status.deadline_exceeded()
  @cancelled GRPC.Status.cancelled()

  @exec_path "/#{GuestAgent.Service.__meta__(:name)}/Exec"
  @wire_max 99_999_999
  @wire_units [{"m", 1}, {"S", 1_000}, {"M", 60_000}, {"H", 3_600_000}]

  @default_timeout 30_000

  @type result ::
          {:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}} | {:error, term()}

  @doc """
  Deterministic host-side path for the per-VM relay Unix socket.

  Derived from `Hyper.Cfg.Dirs.socket_dir/0` so both this client and the
  relay GenServer agree without a registry lookup.
  """
  @spec relay_socket_path(Hyper.Vm.Id.t()) :: Path.t()
  def relay_socket_path(vm_id) do
    # Vm.Id chars are [a-z2-7] plus a 'v' prefix — safe as a filename
    # component without further sanitization.
    Path.join(Hyper.Cfg.Dirs.socket_dir(), "grpc-#{vm_id}.sock")
  end

  @doc """
  Run `argv` in the guest VM identified by `vm_id` via gRPC through the relay.

  Returns `{:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}`,
  or `{:error, term()}`. Error values: `:agent_unavailable` (relay unreachable —
  gRPC UNAVAILABLE), `:timeout` (the call did not finish within `:timeout`),
  `{:bad_agent_reply, reason}` (the reply did not decode), or raw transport
  errors for unexpected failures, including a reply over the relay's 16 MiB cap.

  ## Options

    - `:env` — environment map `%{String.t() => String.t()}` for the guest process
    - `:cwd` — working directory inside the guest (`nil` → not set)
    - `:timeout` — deadline for the whole call in milliseconds (default: #{@default_timeout})
  """
  @spec exec(Hyper.Vm.Id.t(), [String.t()], keyword()) :: result()
  def exec(vm_id, argv, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    req = %ExecRequest{
      argv: argv,
      env: Map.new(Keyword.get(opts, :env, %{})),
      cwd: opts[:cwd]
    }

    path = vm_id |> relay_socket_path() |> String.to_charlist()

    # The caller owns the connection: gun monitors its owner, so a killed
    # caller takes the socket, and the relay's vsock leg, down with it, without
    # draining the hung stream for gun's default 15 s closing_timeout. With
    # retry: 0 an unreachable relay is a prompt :down instead of reconnects.
    {:ok, conn} =
      :gun.open_unix(path, %{
        protocols: [:http2],
        retry: 0,
        http2_opts: %{closing_timeout: 1}
      })

    try do
      call(conn, req, timeout, deadline)
    after
      _ = :gun.close(conn)
      :gun.flush(conn)
    end
  end

  @spec call(pid(), ExecRequest.t(), non_neg_integer(), integer()) :: result()
  defp call(conn, req, timeout, deadline) do
    case :gun.await_up(conn, remaining(deadline)) do
      {:ok, :http2} ->
        msg = ExecRequest.encode(req)
        body = <<0, byte_size(msg)::32, msg::binary>>
        ref = :gun.post(conn, @exec_path, headers(timeout), body)
        await_response(conn, ref, deadline)

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :agent_unavailable}
    end
  end

  @spec headers(non_neg_integer()) :: [{String.t(), String.t()}]
  defp headers(timeout) do
    [
      {"content-type", "application/grpc"},
      {"te", "trailers"},
      {"grpc-timeout", wire_timeout(timeout)}
    ]
  end

  # grpc-timeout carries at most 8 digits: take the finest unit that fits and
  # round up, so the guest never gives up before the host's deadline.
  @spec wire_timeout(non_neg_integer()) :: String.t()
  defp wire_timeout(ms) do
    Enum.find_value(@wire_units, "#{@wire_max}H", fn {unit, unit_ms} ->
      n = div(ms + unit_ms - 1, unit_ms)
      if n <= @wire_max, do: "#{n}#{unit}"
    end)
  end

  @spec await_response(pid(), reference(), integer()) :: result()
  defp await_response(conn, ref, deadline) do
    case :gun.await(conn, ref, remaining(deadline)) do
      {:response, fin, 200, headers} ->
        cond do
          not grpc?(headers) -> {:error, {:bad_agent_reply, {:content_type, ctype(headers)}}}
          fin == :fin -> reply(headers, "")
          true -> await_body(conn, ref, deadline, [])
        end

      {:response, _fin, status, _headers} ->
        {:error, {:bad_agent_reply, {:http_status, status}}}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, _} ->
        {:error, :agent_unavailable}

      _ ->
        await_response(conn, ref, deadline)
    end
  end

  @spec await_body(pid(), reference(), integer(), iodata()) :: result()
  defp await_body(conn, ref, deadline, acc) do
    case :gun.await(conn, ref, remaining(deadline)) do
      {:data, :nofin, data} -> await_body(conn, ref, deadline, [acc | data])
      {:data, :fin, _data} -> {:error, {:bad_agent_reply, :no_trailers}}
      {:trailers, trailers} -> reply(trailers, IO.iodata_to_binary(acc))
      {:error, _} = err -> err
      _ -> await_body(conn, ref, deadline, acc)
    end
  end

  @spec reply([{binary(), binary()}], binary()) :: result()
  defp reply(trailers, body) do
    case {trailers |> header("grpc-status") |> Num.Int.parse_unsigned(), body} do
      {{:ok, 0}, <<0, len::32, msg::binary-size(len)>>} -> decode(msg)
      {{:ok, 0}, _} -> {:error, {:bad_agent_reply, :framing}}
      {{:ok, code}, _} -> map_status(code, trailers |> header("grpc-message") |> percent_decode())
      {:error, _} -> {:error, {:bad_agent_reply, :grpc_status}}
    end
  end

  @spec decode(binary()) :: result()
  defp decode(msg) do
    resp = ExecResponse.decode(msg)
    {:ok, %{exit_code: resp.exit_code, stdout: resp.stdout, stderr: resp.stderr}}
  rescue
    e -> {:error, {:bad_agent_reply, e.__struct__}}
  end

  # tonic answers a lapsed grpc-timeout with CANCELLED "Timeout expired", not
  # DEADLINE_EXCEEDED.
  @spec map_status(pos_integer(), binary()) :: {:error, term()}
  defp map_status(@unavailable, _message), do: {:error, :agent_unavailable}
  defp map_status(@deadline_exceeded, _message), do: {:error, :timeout}
  defp map_status(@cancelled, "Timeout expired"), do: {:error, :timeout}
  defp map_status(code, message), do: {:error, GRPC.RPCError.exception(code, message)}

  @spec grpc?([{binary(), binary()}]) :: boolean()
  defp grpc?(headers), do: String.starts_with?(ctype(headers), "application/grpc")

  @spec ctype([{binary(), binary()}]) :: binary()
  defp ctype(headers), do: header(headers, "content-type")

  @spec header([{binary(), binary()}], String.t()) :: binary()
  defp header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> value
      nil -> ""
    end
  end

  @spec percent_decode(binary()) :: binary()
  defp percent_decode(message) do
    URI.decode(message)
  rescue
    ArgumentError -> message
  end

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
