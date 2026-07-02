defmodule Hyper.Node.FireVMM.Agent.Relay do
  @moduledoc """
  Per-VM gRPC relay: listens on a host Unix-domain socket and for each
  inbound connection performs the Firecracker vsock CONNECT/OK handshake
  via `RelayDialer`, then pipes bytes bidirectionally until either side
  closes.

  Process topology:
  - The GenServer owns the listen socket and spawns a linked acceptor
    process via `handle_continue`. The acceptor blocks on `:socket.accept`
    without blocking the GenServer itself.
  - Each accepted connection spawns an unlinked connection process that
    calls `RelayDialer.dial/3` then monitors two unlinked pipe workers (one
    per direction). A pipe crash tears down only that connection — it cannot
    propagate to the acceptor or to other connections.
  - `terminate/2` closes the listen socket (which causes the acceptor to
    exit on its next accept call) and removes the socket file so a
    subsequent `start_link` with the same path can rebind.
  """

  use GenServer

  alias Hyper.Node.FireVMM.Agent.RelayDialer

  @vsock_port 1024
  @dial_timeout_ms 5_000

  @spec start_link(%{
          required(:vm_id) => term(),
          required(:vsock_uds) => Path.t(),
          required(:listen_path) => Path.t(),
          optional(:name) => GenServer.name()
        }) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if name = Map.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @spec listen_path(GenServer.server()) :: Path.t()
  def listen_path(server), do: GenServer.call(server, :listen_path)

  @impl GenServer
  def init(%{vsock_uds: vsock_uds, listen_path: listen_path, vm_id: vm_id}) do
    Process.flag(:trap_exit, true)
    _ = File.rm(listen_path)
    {:ok, sock} = :socket.open(:local, :stream)
    :ok = :socket.bind(sock, %{family: :local, path: listen_path})
    :ok = :socket.listen(sock, 16)

    {:ok, %{listen: sock, listen_path: listen_path, vsock_uds: vsock_uds, vm_id: vm_id},
     {:continue, :start_acceptor}}
  end

  @impl GenServer
  def handle_continue(:start_acceptor, state) do
    _ = spawn_link(fn -> accept_loop(state.listen, state.vsock_uds) end)
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:listen_path, _from, state) do
    {:reply, state.listen_path, state}
  end

  @impl GenServer
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = :socket.close(state.listen)
    _ = File.rm(state.listen_path)
    :ok
  end

  defp accept_loop(listen_sock, vsock_uds) do
    case :socket.accept(listen_sock) do
      {:ok, client} ->
        _ = spawn(fn -> handle_connection(client, vsock_uds) end)
        accept_loop(listen_sock, vsock_uds)

      {:error, _} ->
        :ok
    end
  end

  defp handle_connection(client_sock, vsock_uds) do
    case RelayDialer.dial(vsock_uds, @vsock_port, @dial_timeout_ms) do
      {:ok, upstream_sock} ->
        p1 = spawn(fn -> pipe_bytes(client_sock, upstream_sock) end)
        p2 = spawn(fn -> pipe_bytes(upstream_sock, client_sock) end)
        ref1 = Process.monitor(p1)
        ref2 = Process.monitor(p2)
        await_pipe_end(client_sock, upstream_sock, p1, p2, ref1, ref2)

      {:error, _} ->
        :socket.close(client_sock)
    end
  end

  defp await_pipe_end(client, upstream, p1, p2, ref1, ref2) do
    receive do
      {:DOWN, ^ref1, :process, ^p1, _} ->
        _ = Process.demonitor(ref2, [:flush])
        _ = Process.exit(p2, :kill)
        _ = :socket.close(client)
        _ = :socket.close(upstream)

      {:DOWN, ^ref2, :process, ^p2, _} ->
        _ = Process.demonitor(ref1, [:flush])
        _ = Process.exit(p1, :kill)
        _ = :socket.close(client)
        _ = :socket.close(upstream)
    end
  end

  defp pipe_bytes(from, to) do
    case :socket.recv(from) do
      {:ok, data} ->
        case send_all(to, data) do
          :ok -> pipe_bytes(from, to)
          {:error, _} -> :ok
        end

      {:error, _} ->
        :ok
    end
  end

  defp send_all(sock, data) do
    case :socket.send(sock, data) do
      :ok -> :ok
      {:ok, rest} -> send_all(sock, rest)
      {:error, _} = err -> err
    end
  end
end
