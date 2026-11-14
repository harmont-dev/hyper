defmodule Hyper.Firecracker.Api.TransportCapPropertiesTest do
  @moduledoc """
  The 1 MiB reply cap of `Hyper.Firecracker.Api.Transport`, held against a
  daemon that controls every byte on the wire (a compromised, jailed
  Firecracker), not just a well-behaved `content-length` responder.

  Laws:

    * size oracle: whatever the framing (`content-length`, chunked with any
      chunk split, close-delimited) and whatever the status, a reply body of
      `n` bytes is classified by the ordinary result contract when
      `n <= 1 MiB` and is `{:error, {:body_too_large, 1 MiB}}` when
      `n > 1 MiB`;
    * the cap bounds work, not just the result: a lying `content-length` or an
      endless stream is refused as soon as the cap is crossed, without waiting
      for bytes that will never come or reading bytes that never end;
    * a refused reply never poisons the socket: the next request on the same
      daemon sees its own reply, not the remainder of the refused one;
    * a reply to a typed operation is the schema struct or an error, never a
      raw non-object passed off as `{:ok, _}`;
    * a single call is bounded in wall time below `Client.run/2`'s call
      timeout, so a drip-feeding daemon cannot wedge the per-VM client.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Firecracker.Api.{InstanceInfo, Transport}

  @cap Unit.Information.as_bytes(Unit.Information.mib(1))
  @client_call_timeout :timer.seconds(35)

  defmodule RawDaemon do
    @moduledoc false

    @spec start((:gen_tcp.socket(), non_neg_integer() -> :close | :keep)) :: Path.t()
    def start(respond) do
      path = Path.join(System.tmp_dir!(), "fc-raw-#{System.unique_integer([:positive])}.sock")

      {:ok, listen} =
        :gen_tcp.listen(0, [
          :binary,
          ifaddr: {:local, String.to_charlist(path)},
          packet: :http_bin,
          active: false,
          send_timeout: 5_000
        ])

      counter = :counters.new(1, [])
      server = spawn(fn -> accept_loop(listen, respond, counter) end)

      ExUnit.Callbacks.on_exit(fn ->
        Process.exit(server, :kill)
        :gen_tcp.close(listen)
        File.rm(path)
      end)

      path
    end

    defp accept_loop(listen, respond, counter) do
      case :gen_tcp.accept(listen) do
        {:ok, sock} ->
          spawn(fn -> serve(sock, respond, counter) end)
          accept_loop(listen, respond, counter)

        {:error, _} ->
          :ok
      end
    end

    defp serve(sock, respond, counter) do
      :ok = :inet.setopts(sock, packet: :http_bin)

      with :ok <- read_request(sock) do
        :counters.add(counter, 1, 1)

        case respond.(sock, :counters.get(counter, 1)) do
          :keep -> serve(sock, respond, counter)
          :close -> :gen_tcp.close(sock)
        end
      end
    end

    defp read_request(sock) do
      case :gen_tcp.recv(sock, 0) do
        {:ok, {:http_request, _, _, _}} -> read_headers(sock, 0)
        _ -> :closed
      end
    end

    defp read_headers(sock, length) do
      case :gen_tcp.recv(sock, 0) do
        {:ok, {:http_header, _, :"Content-Length", _, value}} ->
          read_headers(sock, String.to_integer(value))

        {:ok, {:http_header, _, _, _, _}} ->
          read_headers(sock, length)

        {:ok, :http_eoh} ->
          :ok = :inet.setopts(sock, packet: :raw)
          if length > 0, do: {:ok, _} = :gen_tcp.recv(sock, length)
          :ok

        _ ->
          :closed
      end
    end
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:req)
    :ok
  end

  defp request(path, extra \\ []) do
    Map.merge(%{method: :get, url: "/", opts: [socket_path: path]}, Map.new(extra))
  end

  defp json_of_size(n) do
    shell = ~s({"x":""})
    ~s({"x":") <> String.duplicate("a", n - byte_size(shell)) <> ~s("})
  end

  defp split(body, sizes) do
    Enum.reduce_while(Stream.cycle(sizes), {body, []}, fn
      _size, {"", acc} ->
        {:halt, {"", acc}}

      size, {rest, acc} ->
        take = min(size, byte_size(rest))
        <<chunk::binary-size(^take), tail::binary>> = rest
        {:cont, {tail, [chunk | acc]}}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp send_reply(sock, status, body, :content_length, _sizes) do
    :gen_tcp.send(sock, [
      "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
      body
    ])
  end

  defp send_reply(sock, status, body, :chunked, sizes) do
    _ =
      :gen_tcp.send(
        sock,
        "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\n" <>
          "transfer-encoding: chunked\r\nconnection: close\r\n\r\n"
      )

    for chunk <- split(body, sizes) do
      :gen_tcp.send(sock, [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"])
    end

    :gen_tcp.send(sock, "0\r\n\r\n")
  end

  defp send_reply(sock, status, body, :close_delimited, sizes) do
    _ =
      :gen_tcp.send(
        sock,
        "HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\nconnection: close\r\n\r\n"
      )

    for chunk <- split(body, sizes), do: :gen_tcp.send(sock, chunk)
  end

  defp size_around_cap do
    one_of([
      integer((@cap - 64)..(@cap + 64)),
      integer(16..4096),
      integer((@cap + 65)..(3 * @cap))
    ])
  end

  property "a reply is refused exactly when its body exceeds 1 MiB, under every framing and status" do
    check all(
            size <- size_around_cap(),
            framing <- member_of([:content_length, :chunked, :close_delimited]),
            status <- member_of([200, 400, 500]),
            sizes <- list_of(integer(1..200_000), min_length: 1, max_length: 6),
            max_runs: 60
          ) do
      body = json_of_size(size)

      path =
        RawDaemon.start(fn sock, _n ->
          _ = send_reply(sock, status, body, framing, sizes)
          :close
        end)

      got = Transport.request(request(path))

      expected =
        cond do
          size > @cap -> {:error, {:body_too_large, @cap}}
          status == 200 -> {:ok, %{"x" => String.duplicate("a", size - 8)}}
          true -> {:error, {:api, status, nil}}
        end

      assert got == expected, "#{size} bytes, #{framing}, #{status}"
    end
  end

  test "a lying content-length is refused once the cap is crossed, not after the advertised length" do
    path =
      RawDaemon.start(fn sock, _n ->
        _ =
          :gen_tcp.send(sock, [
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
            "content-length: #{1024 * @cap}\r\n\r\n",
            String.duplicate("a", 2 * @cap)
          ])

        Process.sleep(:infinity)
      end)

    {micros, got} = :timer.tc(fn -> Transport.request(request(path)) end)

    assert got == {:error, {:body_too_large, @cap}}
    assert micros < 5_000_000, "took #{div(micros, 1000)} ms"
  end

  test "an endless chunked stream is refused rather than read forever" do
    path =
      RawDaemon.start(fn sock, _n ->
        _ = :gen_tcp.send(sock, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
        chunk = String.duplicate("a", 65_536)
        frame = [Integer.to_string(byte_size(chunk), 16), "\r\n", chunk, "\r\n"]

        Stream.repeatedly(fn -> :gen_tcp.send(sock, frame) end)
        |> Enum.find(&match?({:error, _}, &1))

        :close
      end)

    task = Task.async(fn -> Transport.request(request(path)) end)

    assert Task.yield(task, 10_000) == {:ok, {:error, {:body_too_large, @cap}}}
  end

  test "after a refused reply on a kept-alive connection the next request reads its own reply" do
    path =
      RawDaemon.start(fn sock, n ->
        body = if n == 1, do: json_of_size(2 * @cap), else: ~s({"n":#{n}})

        _ =
          :gen_tcp.send(sock, [
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\n",
            "content-length: #{byte_size(body)}\r\n\r\n",
            body
          ])

        :keep
      end)

    assert Transport.request(request(path)) == {:error, {:body_too_large, @cap}}
    assert {:ok, %{"n" => n}} = Transport.request(request(path))
    assert is_integer(n)
  end

  test "a typed reply that is not a JSON object is never {:ok, non-struct}" do
    rows = [
      {"empty body", "", "application/json"},
      {"JSON array", "[1,2,3]", "application/json"},
      {"JSON string", ~s("Running"), "application/json"},
      {"JSON null", "null", "application/json"},
      {"plain text", "Running", "text/plain"}
    ]

    leaks =
      for {name, body, type} <- rows,
          got = typed_reply(body, type),
          not (match?({:ok, %InstanceInfo{}}, got) or match?({:error, _}, got)),
          do: {name, got}

    assert leaks == []
  end

  defp typed_reply(body, type) do
    path =
      RawDaemon.start(fn sock, _n ->
        _ =
          :gen_tcp.send(sock, [
            "HTTP/1.1 200 OK\r\ncontent-type: #{type}\r\n",
            "content-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n",
            body
          ])

        :close
      end)

    Transport.request(request(path, response: [{200, {InstanceInfo, :t}}]))
  end

  @tag timeout: 120_000
  test "a drip-fed reply is cut off before Client.run/2's call timeout" do
    path =
      RawDaemon.start(fn sock, _n ->
        _ =
          :gen_tcp.send(
            sock,
            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: 1000\r\n\r\n"
          )

        Stream.repeatedly(fn ->
          Process.sleep(2_000)
          :gen_tcp.send(sock, " ")
        end)
        |> Enum.find(&match?({:error, _}, &1))

        :close
      end)

    task = Task.async(fn -> Transport.request(request(path)) end)
    got = Task.yield(task, @client_call_timeout) || Task.shutdown(task, :brutal_kill)

    assert match?({:ok, {:error, _}}, got),
           "Transport.request still running after #{@client_call_timeout} ms: #{inspect(got)}"
  end
end
