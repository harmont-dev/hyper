defmodule Hyper.Firecracker.Api.Transport do
  @moduledoc """
  `oapi_generator` client backend for the Firecracker API. Each generated
  operation calls `request/1` with a plain map describing the call; this issues
  it over the target daemon's HTTP-over-Unix-socket API via `Req` and decodes the
  typed response.

  The per-VM socket path arrives as `opts[:socket_path]` (injected by
  `Hyper.Node.FireVMM.Client`). Request bodies are generated structs encoded by
  `Hyper.Firecracker.Api.Codec` (nil-stripped) or, for free-form bodies like
  MMDS, plain maps sent verbatim. Typed responses are decoded by the schema's
  own generated `decode/1` (also from `Hyper.Firecracker.Api.Codec`).

  Returns: `:ok` (204 / empty), `{:ok, decoded}` (2xx with a typed body),
  `{:error, {:api, status, fault_message}}` (non-2xx), or
  `{:error, {:transport, reason}}` (socket/connection failure).
  """

  use OpenTelemetryDecorator

  alias Unit.Information

  @max_body_bytes Information.as_bytes(Information.mib(1))

  # A hostile daemon controls every byte of the reply, so the head is bounded
  # as tightly as the body: the length of each status, header, chunk-size and
  # trailer line, and how many of them there may be.
  @max_line_bytes Information.as_bytes(Information.kib(8))
  @max_headers 100

  # One deadline for the whole call, below `Hyper.Node.FireVMM.Client`'s 35 s
  # call cap, so a daemon drip-feeding bytes cannot keep the client busy.
  @call_budget_ms Unit.Time.as_ms(Unit.Time.s(30))

  @type result ::
          :ok
          | {:ok, term()}
          | {:error,
             {:api, pos_integer(), String.t() | nil}
             | {:transport, term()}
             | {:body_too_large, pos_integer()}
             | {:unexpected_body, pos_integer()}}

  @spec request(map()) :: result()
  @decorate with_span("Hyper.Firecracker.Api.Transport.request", include: [:method, :url])
  def request(%{method: method, url: url, opts: opts} = info) do
    deadline = System.monotonic_time(:millisecond) + @call_budget_ms

    case call(Keyword.fetch!(opts, :socket_path), encode(method, url, info), deadline) do
      {:ok, status, headers, body} ->
        handle(status, decode(headers, body), Map.get(info, :response, []))

      {:error, :body_too_large} ->
        {:error, {:body_too_large, @max_body_bytes}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @spec encode(atom(), String.t(), map()) :: iodata()
  defp encode(method, url, info) do
    target = if q = info[:query], do: url <> "?" <> URI.encode_query(q), else: url

    {headers, body} =
      case Map.fetch(info, :body) do
        {:ok, body} ->
          json = Jason.encode_to_iodata!(body)

          {[
             "content-type: application/json\r\naccept: application/json\r\n",
             "content-length: #{IO.iodata_length(json)}\r\n"
           ], json}

        :error ->
          {[], []}
      end

    [
      method |> Atom.to_string() |> String.upcase(),
      " ",
      target,
      " HTTP/1.1\r\nhost: localhost\r\n",
      headers,
      "\r\n",
      body
    ]
  end

  defp call(socket_path, request, deadline) do
    opts = [:binary, active: false, packet: :raw, send_timeout: @call_budget_ms]

    with {:ok, sock} <- :gen_tcp.connect({:local, socket_path}, 0, opts, remaining(deadline)) do
      try do
        with :ok <- :gen_tcp.send(sock, request),
             {:ok, status, headers} <- read_head(sock, deadline),
             {:ok, body} <- read_body(sock, status, headers, deadline) do
          {:ok, status, headers, body}
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  defp read_head(sock, deadline) do
    :ok = :inet.setopts(sock, packet: :http_bin, packet_size: @max_line_bytes)

    case recv(sock, 0, deadline) do
      {:ok, {:http_response, _version, status, _reason}} ->
        read_headers(sock, status, %{}, 0, deadline)

      {:ok, _other} ->
        {:error, :malformed_status_line}

      {:error, :emsgsize} ->
        {:error, :line_too_long}

      {:error, _} = err ->
        err
    end
  end

  defp read_headers(_sock, _status, _headers, count, _deadline) when count > @max_headers,
    do: {:error, :too_many_headers}

  defp read_headers(sock, status, headers, count, deadline) do
    case recv(sock, 0, deadline) do
      {:ok, {:http_header, _, name, _, value}} ->
        headers = Map.put(headers, header_name(name), value)
        read_headers(sock, status, headers, count + 1, deadline)

      {:ok, :http_eoh} ->
        {:ok, status, headers}

      {:ok, _other} ->
        {:error, :malformed_header}

      {:error, :emsgsize} ->
        {:error, :line_too_long}

      {:error, _} = err ->
        err
    end
  end

  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(name), do: String.downcase(name)

  defp read_body(_sock, status, _headers, _deadline)
       when status in 100..199 or status in [204, 304],
       do: {:ok, ""}

  defp read_body(sock, _status, headers, deadline) do
    :ok = :inet.setopts(sock, packet: :raw)

    cond do
      chunked?(headers) -> read_chunks(sock, [], 0, deadline)
      length = headers["content-length"] -> read_sized(sock, length, deadline)
      true -> read_to_close(sock, [], 0, deadline)
    end
  end

  defp chunked?(%{"transfer-encoding" => coding}),
    do: coding |> String.downcase() |> String.contains?("chunked")

  defp chunked?(_headers), do: false

  defp read_sized(sock, length, deadline) do
    case Integer.parse(length) do
      {0, ""} -> {:ok, ""}
      {n, ""} when n > @max_body_bytes -> {:error, :body_too_large}
      {n, ""} when n > 0 -> recv(sock, n, deadline)
      _ -> {:error, :bad_content_length}
    end
  end

  defp read_to_close(sock, acc, size, deadline) do
    case recv(sock, 0, deadline) do
      {:ok, data} when size + byte_size(data) > @max_body_bytes -> {:error, :body_too_large}
      {:ok, data} -> read_to_close(sock, [acc | data], size + byte_size(data), deadline)
      {:error, :closed} -> {:ok, IO.iodata_to_binary(acc)}
      {:error, _} = err -> err
    end
  end

  defp read_chunks(sock, acc, size, deadline) do
    with {:ok, line} <- read_line(sock, deadline),
         {:ok, chunk_size} <- chunk_size(line) do
      cond do
        chunk_size == 0 ->
          with :ok <- skip_trailers(sock, 0, deadline), do: {:ok, IO.iodata_to_binary(acc)}

        size + chunk_size > @max_body_bytes ->
          {:error, :body_too_large}

        true ->
          with {:ok, chunk} <- recv(sock, chunk_size, deadline),
               :ok <- expect_crlf(sock, deadline) do
            read_chunks(sock, [acc | chunk], size + chunk_size, deadline)
          end
      end
    end
  end

  defp chunk_size(line) do
    [hex | _extensions] = String.split(line, ";", parts: 2)

    case Integer.parse(String.trim(hex), 16) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :malformed_chunk}
    end
  end

  defp expect_crlf(sock, deadline) do
    case recv(sock, 2, deadline) do
      {:ok, "\r\n"} -> :ok
      {:ok, _other} -> {:error, :malformed_chunk}
      {:error, _} = err -> err
    end
  end

  defp skip_trailers(_sock, count, _deadline) when count > @max_headers,
    do: {:error, :too_many_headers}

  defp skip_trailers(sock, count, deadline) do
    case read_line(sock, deadline) do
      {:ok, "\r\n"} -> :ok
      {:ok, _trailer} -> skip_trailers(sock, count + 1, deadline)
      {:error, _} = err -> err
    end
  end

  defp read_line(sock, deadline) do
    :ok = :inet.setopts(sock, packet: :line, packet_size: @max_line_bytes)
    line = recv(sock, 0, deadline)
    :ok = :inet.setopts(sock, packet: :raw)

    case line do
      {:error, :emsgsize} -> {:error, :line_too_long}
      other -> other
    end
  end

  defp recv(sock, length, deadline), do: :gen_tcp.recv(sock, length, remaining(deadline))

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  @spec decode(%{String.t() => binary()}, binary()) :: term()
  defp decode(headers, body) do
    with true <- body != "" and json?(headers),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
    else
      _ -> body
    end
  end

  defp json?(%{"content-type" => type}) do
    [media | _params] = String.split(type, ";", parts: 2)
    String.downcase(String.trim(media)) == "application/json"
  end

  defp json?(_headers), do: false

  @spec handle(pos_integer(), term(), [{pos_integer(), term()}]) :: result()
  defp handle(status, body, responses) when status in 200..299 do
    case List.keyfind(responses, status, 0) do
      {^status, :null} -> :ok
      {^status, {module, :t}} when is_map(body) -> {:ok, module.decode(body)}
      {^status, {_module, :t}} -> {:error, {:unexpected_body, status}}
      _other -> if body in [nil, ""], do: :ok, else: {:ok, body}
    end
  end

  defp handle(status, body, _responses), do: {:error, {:api, status, fault(body)}}

  @spec fault(term()) :: String.t() | nil
  defp fault(%{"fault_message" => message}), do: message
  defp fault(_), do: nil
end
