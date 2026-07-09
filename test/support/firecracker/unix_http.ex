defmodule Hyper.Firecracker.Support.UnixHttp do
  @moduledoc """
  Minimal HTTP/1.1 server on a Unix-domain socket, standing in for a
  Firecracker daemon so `Hyper.Firecracker.Api.Transport` is exercised over
  the real wire (Req → Finch → Mint over `unix_socket`), not a mock.

  `start/1` takes a responder `fun(request) -> {status, body_iodata}` and
  returns the socket path. Every accepted request is also sent to the
  starting process as `{:unix_http, request}` with
  `%{method: atom, path: String.t(), headers: map, body: binary}`.
  Must be called from a test process: it registers `on_exit/1` cleanup.
  """

  @type request :: %{method: atom(), path: String.t(), headers: map(), body: binary()}

  @spec start((request() -> {pos_integer(), iodata()})) :: Path.t()
  def start(respond) do
    path =
      Path.join(System.tmp_dir!(), "fc-fake-#{System.unique_integer([:positive])}.sock")

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        ifaddr: {:local, String.to_charlist(path)},
        packet: :http_bin,
        active: false
      ])

    owner = self()
    server = spawn_link(fn -> accept_loop(listen, respond, owner) end)

    ExUnit.Callbacks.on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listen)
      File.rm(path)
    end)

    path
  end

  defp accept_loop(listen, respond, owner) do
    case :gen_tcp.accept(listen) do
      {:ok, sock} ->
        request = read_request(sock)
        send(owner, {:unix_http, request})
        {status, body} = respond.(request)
        :ok = :gen_tcp.send(sock, response(status, IO.iodata_to_binary(body)))
        :gen_tcp.close(sock)
        accept_loop(listen, respond, owner)

      {:error, :closed} ->
        :ok
    end
  end

  defp read_request(sock) do
    {:ok, {:http_request, method, {:abs_path, path}, _version}} = :gen_tcp.recv(sock, 0)
    headers = read_headers(sock, %{})
    length = headers |> Map.get("content-length", "0") |> String.to_integer()
    :ok = :inet.setopts(sock, packet: :raw)
    body = if length > 0, do: recv_exact(sock, length), else: ""
    %{method: method, path: to_string(path), headers: headers, body: body}
  end

  defp read_headers(sock, acc) do
    case :gen_tcp.recv(sock, 0) do
      {:ok, {:http_header, _, name, _, value}} ->
        read_headers(sock, Map.put(acc, downcase(name), to_string(value)))

      {:ok, :http_eoh} ->
        acc
    end
  end

  defp downcase(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp downcase(name), do: name |> to_string() |> String.downcase()

  defp recv_exact(sock, length) do
    {:ok, body} = :gen_tcp.recv(sock, length)
    body
  end

  # 204 must carry neither body nor content-length; an empty 200 must not
  # claim application/json or Req's decode step would choke on "".
  defp response(204, _body), do: "HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n"

  defp response(status, "") do
    "HTTP/1.1 #{status} X\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
  end

  defp response(status, body) do
    [
      "HTTP/1.1 #{status} X\r\n",
      "content-type: application/json\r\n",
      "content-length: #{byte_size(body)}\r\n",
      "connection: close\r\n\r\n",
      body
    ]
  end
end
