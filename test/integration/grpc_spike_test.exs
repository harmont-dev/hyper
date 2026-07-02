defmodule Hyper.Integration.GrpcSpikeTest do
  @moduledoc """
  Proves that the Elixir gRPC client (Gun adapter) can speak HTTP/2 to a
  tonic server over a byte-pipe relay — the core transport assumption for
  Task 3 onwards.

  The test does NOT involve a VM or vsock.  It wires:

      Gun client  →  UDS relay (B)  →  tonic Health server (A)

  and asserts that a Health RPC round-trips with ok: true.
  """
  use ExUnit.Case, async: false

  @moduletag :integration

  @agent_crate "native/guest-agent"
  @example_bin "native/guest-agent/target/debug/examples/health_uds"

  setup_all do
    # :grpc starts :gun among its dependencies; it is safe to call this even
    # when the broader :hyper application is not running (--no-start mode).
    {:ok, _} = Application.ensure_all_started(:grpc)

    {_, 0} =
      System.cmd("cargo", ["build", "--example", "health_uds"],
        cd: @agent_crate,
        stderr_to_stdout: true
      )

    :ok
  end

  setup do
    uid = :erlang.unique_integer([:positive])
    a_path = "/tmp/hyper-grpc-agent-#{uid}.sock"
    b_path = "/tmp/hyper-grpc-relay-#{uid}.sock"

    File.rm(a_path)
    File.rm(b_path)

    bin = Path.expand(@example_bin)

    # A dedicated process owns the Port so that on_exit (which runs in a
    # different process) can close it by killing the owner.
    parent = self()

    agent_owner =
      spawn(fn ->
        port = Port.open({:spawn_executable, bin}, [{:args, [a_path]}, :stderr_to_stdout])
        send(parent, {:port_ready, port})

        receive do
          :stop -> Port.close(port)
        end
      end)

    receive do
      {:port_ready, _port} -> :ok
    end

    wait_for_socket(a_path, 5_000)

    relay_pid = start_relay(a_path, b_path)
    wait_for_socket(b_path, 2_000)

    on_exit(fn ->
      send(agent_owner, :stop)
      Process.exit(relay_pid, :kill)
      File.rm(a_path)
      File.rm(b_path)
    end)

    {:ok, b_path: b_path}
  end

  test "Health RPC round-trips through the byte-pipe relay", %{b_path: b_path} do
    {:ok, channel} =
      GRPC.Stub.connect("unix://#{b_path}", adapter: GRPC.Client.Adapters.Gun)

    assert {:ok, %Hyper.Agent.V1.HealthResponse{ok: true}} =
             Hyper.Agent.V1.GuestAgent.Stub.health(channel, %Hyper.Agent.V1.HealthRequest{})

    GRPC.Stub.disconnect(channel)
  end

  defp start_relay(a_path, b_path) do
    spawn(fn ->
      {:ok, srv} = :socket.open(:local, :stream)
      :ok = :socket.bind(srv, %{family: :local, path: b_path})
      :ok = :socket.listen(srv, 5)

      {:ok, client} = :socket.accept(srv)
      :socket.close(srv)

      {:ok, agent} = :socket.open(:local, :stream)
      :ok = :socket.connect(agent, %{family: :local, path: a_path})

      me = self()
      t1 = spawn(fn -> copy_bytes(client, agent, me) end)
      t2 = spawn(fn -> copy_bytes(agent, client, me) end)

      receive do
        :done -> :ok
      end

      Process.exit(t1, :kill)
      Process.exit(t2, :kill)
      :socket.close(client)
      :socket.close(agent)
    end)
  end

  defp copy_bytes(from, to, parent) do
    case :socket.recv(from) do
      {:ok, data} ->
        :socket.send(to, data)
        copy_bytes(from, to, parent)

      {:error, _} ->
        send(parent, :done)
    end
  end

  defp wait_for_socket(path, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(path, deadline)
  end

  defp do_wait(path, deadline) do
    if File.exists?(path) do
      :ok
    else
      remaining = deadline - System.monotonic_time(:millisecond)

      if remaining <= 0 do
        raise "timed out waiting for socket: #{path}"
      end

      Process.sleep(50)
      do_wait(path, deadline)
    end
  end
end
