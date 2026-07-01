defmodule Hyper.Node.FireVMM.ExecTest do
  @moduledoc """
  Round-trip tests for `Hyper.Node.FireVMM.Exec.run/3` against a fake
  AF_UNIX server that mimics Firecracker's vsock multiplexer.

  Two invariants are probed:

  1. **Protocol correctness** — the client sends `CONNECT 1024\\n`, encodes
     the request as a CBOR map, and decodes the response (a CBOR map whose
     `stdout`/`stderr` are byte strings) correctly after reading to EOF.

  2. **Recv-accumulation** — when the server sends the response one byte at a
     time then closes, `run/3` still assembles the correct
     `{exit_code, stdout, stderr}`. This would silently fail for an
     implementation that stopped reading after the first `recv` rather than
     accumulating until the connection closes.
  """

  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Exec

  defp tmp_sock_path do
    Path.join(
      System.tmp_dir!(),
      "exec-test-#{System.unique_integer([:positive])}.sock"
    )
  end

  defp start_fake_server do
    path = tmp_sock_path()
    File.rm(path)

    {:ok, lsock} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, ifaddr: {:local, path}])

    ExUnit.Callbacks.on_exit(fn ->
      :gen_tcp.close(lsock)
      File.rm(path)
    end)

    {path, lsock}
  end

  defp run_fake_server(lsock, handler) do
    Task.async(fn ->
      {:ok, sock} = :gen_tcp.accept(lsock, 5_000)
      assert read_line(sock) == "CONNECT 1024\n"
      :ok = :gen_tcp.send(sock, "OK 99\n")
      handler.(sock)
      :gen_tcp.close(sock)
    end)
  end

  defp read_line(sock), do: read_line(sock, <<>>)

  defp read_line(sock, acc) do
    {:ok, byte} = :gen_tcp.recv(sock, 1, 5_000)
    if byte == "\n", do: acc <> "\n", else: read_line(sock, acc <> byte)
  end

  defp recv_request(sock) do
    {:ok, data} = :gen_tcp.recv(sock, 0, 5_000)
    {:ok, req, _rest} = CBOR.decode(data)
    req
  end

  defp encode_response(exit_code, stdout, stderr) do
    CBOR.encode(%{
      "exit_code" => exit_code,
      "stdout" => %CBOR.Tag{tag: :bytes, value: stdout},
      "stderr" => %CBOR.Tag{tag: :bytes, value: stderr}
    })
  end

  test "round-trip: argv, exit_code, stdout, stderr arrive correctly" do
    {path, lsock} = start_fake_server()

    server =
      run_fake_server(lsock, fn sock ->
        req = recv_request(sock)
        assert req["argv"] == ["echo", "hello"]
        :ok = :gen_tcp.send(sock, encode_response(0, "hello\n", ""))
      end)

    assert {:ok, %{exit_code: 0, stdout: "hello\n", stderr: ""}} =
             Exec.run(path, ["echo", "hello"], connect_timeout: 500)

    Task.await(server, 5_000)
  end

  test "non-zero exit code is preserved" do
    {path, lsock} = start_fake_server()

    server =
      run_fake_server(lsock, fn sock ->
        _req = recv_request(sock)
        :ok = :gen_tcp.send(sock, encode_response(127, "", "cmd not found\n"))
      end)

    assert {:ok, %{exit_code: 127, stdout: "", stderr: "cmd not found\n"}} =
             Exec.run(path, ["nonexistent"], connect_timeout: 500)

    Task.await(server, 5_000)
  end

  test "chunked response is assembled correctly (exercises recv-accumulation)" do
    {path, lsock} = start_fake_server()

    stdout = "chunked output"
    stderr = "chunked err"

    server =
      run_fake_server(lsock, fn sock ->
        _req = recv_request(sock)
        resp = encode_response(42, stdout, stderr)

        for <<byte::8 <- resp>> do
          :ok = :gen_tcp.send(sock, <<byte>>)
          # Slow the send so the client's recv loop is forced to accumulate
          # across multiple calls rather than receiving everything in one shot.
          Process.sleep(1)
        end
      end)

    assert {:ok, %{exit_code: 42, stdout: ^stdout, stderr: ^stderr}} =
             Exec.run(path, ["cmd"], connect_timeout: 500, timeout: 10_000)

    Task.await(server, 10_000)
  end

  test "optional env, cwd, timeout_ms are included in request when set" do
    {path, lsock} = start_fake_server()

    server =
      run_fake_server(lsock, fn sock ->
        req = recv_request(sock)
        assert req["argv"] == ["cmd"]
        assert req["env"] == %{"FOO" => "bar"}
        assert req["cwd"] == "/tmp"
        assert req["timeout_ms"] == 5_000
        :ok = :gen_tcp.send(sock, encode_response(0, "", ""))
      end)

    assert {:ok, %{exit_code: 0}} =
             Exec.run(path, ["cmd"],
               env: %{"FOO" => "bar"},
               cwd: "/tmp",
               timeout_ms: 5_000,
               connect_timeout: 500
             )

    Task.await(server, 5_000)
  end

  test "absent env/cwd/timeout_ms are omitted from request" do
    {path, lsock} = start_fake_server()

    server =
      run_fake_server(lsock, fn sock ->
        req = recv_request(sock)
        refute Map.has_key?(req, "env")
        refute Map.has_key?(req, "cwd")
        refute Map.has_key?(req, "timeout_ms")
        :ok = :gen_tcp.send(sock, encode_response(0, "", ""))
      end)

    assert {:ok, _} = Exec.run(path, ["cmd"], connect_timeout: 500)
    Task.await(server, 5_000)
  end

  test "returns :agent_unavailable when no server is listening within connect_timeout" do
    path = tmp_sock_path()
    assert {:error, :agent_unavailable} = Exec.run(path, ["cmd"], connect_timeout: 200)
  end

  test "CBOR encoder produces the cross-language anchor bytes" do
    assert CBOR.encode(%{"argv" => ["uname", "-a"], "env" => %{"PATH" => "/bin"}}) ==
             Base.decode16!("A264617267768265756E616D65622D6163656E76A16450415448642F62696E")
  end
end
