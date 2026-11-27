defmodule Hyper.Node.FireVMM.AgentWaitTest do
  @moduledoc """
  `Agent.exec/3`'s `:wait_for_agent`, through a real `Relay` and a fake
  firecracker vsock that refuses every `CONNECT` until the guest "boots", as
  firecracker does while nothing in the guest listens, then splices each one to
  an in-process gRPC guest:

  - an exec that waits answers once the agent comes up, not when its wait runs
    out;
  - an exec that does not wait is refused at once, as before;
  - a wait that runs out first is `:agent_unavailable`, not a hang.

  `async: false`: `Hyper.Cfg.Toml.put_cache/1` is process-global.
  """
  use ExUnit.Case, async: false

  alias Hyper.Agent.V1.{ExecResponse, HealthResponse}
  alias Hyper.Node.FireVMM.Agent
  alias Hyper.Node.FireVMM.Agent.Relay
  alias Hyper.Node.FireVMM.Jailer

  @vm_id "vwaitagent"
  @up_at {__MODULE__, :up_at}

  defmodule Guest do
    @moduledoc false
    use GRPC.Server, service: Hyper.Agent.V1.GuestAgent.Service

    def exec(%{argv: ["/bin/echo" | rest]}, _stream),
      do: %ExecResponse{exit_code: 0, stdout: Enum.join(rest, " ")}

    def health(_req, _stream), do: %HealthResponse{ok: true}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:cowboy)
    original = Hyper.Cfg.Toml.reload()
    tmp = Path.join(System.tmp_dir!(), "agent-wait-#{System.unique_integer([:positive])}")
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    File.mkdir_p!(Hyper.Cfg.Dirs.socket_dir())

    guest_path = Path.join(Hyper.Cfg.Dirs.socket_dir(), "guest-#{@vm_id}.sock")
    vsock_path = Jailer.host_vsock(@vm_id)
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
      :persistent_term.erase(@up_at)
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf(tmp)
    end)

    :ok
  end

  test "an exec that waits answers once the agent comes up, not when its wait runs out" do
    up_at = boot_in(150)

    assert {:ok, %{stdout: "up"}} =
             Agent.exec(@vm_id, ["/bin/echo", "up"], timeout: 5_000, wait_for_agent: 5_000)

    answered = System.monotonic_time(:millisecond)
    assert answered >= up_at
    assert answered - up_at < 100
  end

  test "an exec that does not wait is refused at once while the agent is down" do
    _ = boot_in(10_000)

    {us, result} = :timer.tc(fn -> Agent.exec(@vm_id, ["/bin/echo", "x"], timeout: 5_000) end)

    assert result == {:error, :agent_unavailable}
    assert div(us, 1_000) < 1_000
  end

  test "a wait that runs out before the agent comes up is :agent_unavailable" do
    _ = boot_in(10_000)

    {us, result} =
      :timer.tc(fn ->
        Agent.exec(@vm_id, ["/bin/echo", "x"], timeout: 5_000, wait_for_agent: 200)
      end)

    assert result == {:error, :agent_unavailable}
    assert div(us, 1_000) in 200..1_000
  end

  # The fake guest's agent starts listening `ms` from now; returns that instant.
  defp boot_in(ms) do
    up_at = System.monotonic_time(:millisecond) + ms
    :persistent_term.put(@up_at, up_at)
    up_at
  end

  defp fake_firecracker(listen, guest_path) do
    with {:ok, vsock} <- :socket.accept(listen) do
      _ = spawn(fn -> connect(vsock, guest_path) end)
      fake_firecracker(listen, guest_path)
    end
  end

  defp connect(vsock, guest_path) do
    {:ok, "CONNECT " <> _} = :socket.recv(vsock)

    if System.monotonic_time(:millisecond) >= :persistent_term.get(@up_at) do
      splice(vsock, guest_path)
    else
      :socket.close(vsock)
    end
  end

  defp splice(vsock, guest_path) do
    :ok = :socket.send(vsock, "OK 5\n")
    {:ok, guest} = :socket.open(:local, :stream)
    :ok = :socket.connect(guest, %{family: :local, path: guest_path})
    _ = spawn(fn -> pipe(guest, vsock) end)
    pipe(vsock, guest)
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
end
