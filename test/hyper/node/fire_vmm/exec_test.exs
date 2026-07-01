defmodule Hyper.Node.FireVMM.ExecTest do
  @moduledoc """
  Round-trip tests for `Hyper.Node.FireVMM.Exec.run/3` against a fake
  AF_UNIX server that mimics Firecracker's vsock multiplexer.

  Two invariants are probed:

  1. **Protocol correctness** — the client sends `CONNECT 1024\\n`, encodes the
     request frame (len-prefix + JSON), and decodes the response frame
     (exit-code + stdout + stderr) correctly.

  2. **Recv-accumulation** — when the server sends the response one byte at a
     time, `run/3` still assembles the correct `{exit_code, stdout, stderr}`.
     This would silently fail for an implementation that assumed a single
     `recv` returns a complete frame.
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
    {:ok, <<len::32>>} = :gen_tcp.recv(sock, 4, 5_000)
    {:ok, json} = :gen_tcp.recv(sock, len, 5_000)
    Jason.decode!(json)
  end

  defp encode_response(exit_code, stdout, stderr) do
    <<exit_code::32-signed>> <>
      <<byte_size(stdout)::32>> <>
      stdout <>
      <<byte_size(stderr)::32>> <>
      stderr
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
          # Force the receiver to consume one byte at a time. Without the
          # accumulation loop in recv_exactly, a caller that read exactly
          # N bytes in one shot could still pass — but if the implementation
          # ever switched to recv(sock, 0, …) without accumulation, it would
          # return after the first byte and misparse the frame.
          Process.sleep(1)
        end
      end)

    assert {:ok, %{exit_code: 42, stdout: ^stdout, stderr: ^stderr}} =
             Exec.run(path, ["cmd"], connect_timeout: 500, timeout: 10_000)

    Task.await(server, 10_000)
  end

  test "optional env, cwd, timeout_ms are included in request JSON when set" do
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

  test "absent env/cwd/timeout_ms are omitted from request JSON" do
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
end
