defmodule Hyper.Node.FireVMM.AgentRelayTest do
  @moduledoc """
  `Agent.exec/3` through a real `Relay` and a fake Firecracker vsock that
  splices each `CONNECT` to an in-process gRPC guest:

  - a reply under the relay's 16 MiB cap round-trips intact: the cap bounds
    a hostile guest, it must not truncate or reject an honest large reply;
  - a reply over the cap is an error that is not `:timeout`, and the relay
    keeps serving: the next exec on the same VM succeeds;
  - concurrent execs on one VM each get their own reply, never another
    call's.

  `async: false`: `Hyper.Cfg.Toml.put_cache/1` is process-global.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Agent.V1.{ExecResponse, HealthResponse}
  alias Hyper.Node.FireVMM.Agent
  alias Hyper.Node.FireVMM.Agent.Relay
  alias Unit.Information

  @vm_id "vrelayexec"

  defmodule Guest do
    @moduledoc false
    use GRPC.Server, service: Hyper.Agent.V1.GuestAgent.Service

    def exec(%{argv: ["/bin/head", bytes]}, _stream),
      do: %ExecResponse{exit_code: 0, stdout: :binary.copy("y", String.to_integer(bytes))}

    def exec(%{argv: ["/bin/echo" | rest]}, _stream) do
      Process.sleep(:rand.uniform(50))
      %ExecResponse{exit_code: 0, stdout: Enum.join(rest, " ")}
    end

    def health(_req, _stream), do: %HealthResponse{ok: true}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:cowboy)
    original = Hyper.Cfg.Toml.reload()
    tmp = Path.join(System.tmp_dir!(), "agent-relay-#{System.unique_integer([:positive])}")
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    dir = Hyper.Cfg.Dirs.socket_dir()
    File.mkdir_p!(dir)

    guest_path = Path.join(dir, "guest-#{@vm_id}.sock")
    vsock_path = Path.join(dir, "vsock-#{@vm_id}.sock")
    {:ok, _pid, _port} = GRPC.Server.start(Guest, 0, adapter_opts: [ip: {:local, guest_path}])

    {:ok, fc} = :socket.open(:local, :stream)
    :ok = :socket.bind(fc, %{family: :local, path: vsock_path})
    :ok = :socket.listen(fc, 64)
    firecracker = spawn(fn -> fake_firecracker(fc, guest_path) end)

    {:ok, relay} =
      Relay.start_link(%{
        vm_id: @vm_id,
        vsock_uds: vsock_path,
        listen_path: Agent.relay_socket_path(@vm_id)
      })

    true = Process.unlink(relay)

    on_exit(fn ->
      GenServer.stop(relay)
      Process.exit(firecracker, :kill)
      GRPC.Server.stop(Guest)
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp fake_firecracker(listen, guest_path) do
    with {:ok, vsock} <- :socket.accept(listen) do
      splice(vsock, guest_path)
      fake_firecracker(listen, guest_path)
    end
  end

  defp splice(vsock, guest_path) do
    spawn(fn ->
      {:ok, "CONNECT " <> _} = :socket.recv(vsock)
      :ok = :socket.send(vsock, "OK 5\n")
      {:ok, guest} = :socket.open(:local, :stream)
      :ok = :socket.connect(guest, %{family: :local, path: guest_path})
      _ = spawn(fn -> pipe(guest, vsock) end)
      pipe(vsock, guest)
    end)
  end

  defp pipe(from, to) do
    with {:ok, data} <- :socket.recv(from),
         :ok <- :socket.send(to, data) do
      pipe(from, to)
    else
      _ ->
        :socket.close(from)
        :socket.close(to)
    end
  end

  test "an honest reply under the cap round-trips intact" do
    for mib <- [1, 5, 15] do
      bytes = Information.as_bytes(Information.mib(mib))

      assert {:ok, %{exit_code: 0, stdout: stdout}} =
               Agent.exec(@vm_id, ["/bin/head", "#{bytes}"], timeout: 20_000)

      assert {mib, byte_size(stdout), stdout == :binary.copy("y", bytes)} == {mib, bytes, true}
    end
  end

  test "a reply over the cap is a non-timeout error and the relay keeps serving" do
    over = Information.as_bytes(Information.mib(17))

    assert {:error, reason} = Agent.exec(@vm_id, ["/bin/head", "#{over}"], timeout: 20_000)
    assert reason != :timeout

    assert {:ok, %{stdout: "still here"}} =
             Agent.exec(@vm_id, ["/bin/echo", "still", "here"], timeout: 5_000)
  end

  property "concurrent execs on one VM each get their own reply" do
    check all(
            words <-
              uniq_list_of(string(:alphanumeric, min_length: 1), min_length: 2, max_length: 16),
            max_runs: 10
          ) do
      results =
        words
        |> Task.async_stream(&Agent.exec(@vm_id, ["/bin/echo", &1], timeout: 10_000),
          max_concurrency: length(words),
          timeout: 15_000
        )
        |> Enum.map(fn {:ok, {:ok, %{stdout: out}}} -> out end)

      assert results == words
    end
  end
end
