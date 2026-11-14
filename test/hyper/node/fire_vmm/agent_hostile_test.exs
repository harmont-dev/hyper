defmodule Hyper.Node.FireVMM.AgentHostileTest do
  use ExUnit.Case, async: false

  alias Hyper.Agent.V1.ExecResponse
  alias Hyper.Node.FireVMM.Agent
  alias Hyper.Node.FireVMM.Agent.Relay
  alias Unit.Information

  @deadline_ms 500
  @flood_deadline_ms 10_000

  defmodule Guest do
    @moduledoc false

    def init(req, mode) do
      {:ok, _body, req} = :cowboy_req.read_body(req)
      req = :cowboy_req.stream_reply(200, %{"content-type" => "application/grpc"}, req)
      reply(mode, req)
      {:ok, req, mode}
    end

    defp reply(:undecodable, req) do
      garbage = <<0xFF, 0xFF, 0xFF>>
      :cowboy_req.stream_body(<<0, byte_size(garbage)::32, garbage::binary>>, :nofin, req)
      :cowboy_req.stream_trailers(%{"grpc-status" => "0"}, req)
    end

    defp reply(:bad_trailer, req) do
      trailer = "no-colon-here"
      body = <<0, 0::32, 0x80, byte_size(trailer)::32, trailer::binary>>
      :cowboy_req.stream_body(body, :nofin, req)
      :cowboy_req.stream_trailers(%{"grpc-status" => "0"}, req)
    end

    defp reply(:flood, req) do
      stdout = :binary.copy("x", Information.as_bytes(Information.mib(32)))
      msg = ExecResponse.encode(%ExecResponse{stdout: stdout, exit_code: 0})
      :cowboy_req.stream_body(<<0, byte_size(msg)::32, msg::binary>>, :nofin, req)
      :cowboy_req.stream_trailers(%{"grpc-status" => "0"}, req)
    end

    defp reply(:trickle, req) do
      :cowboy_req.stream_body(<<0, 1_000_000::32>>, :nofin, req)

      Enum.each(1..1_000, fn _ ->
        Process.sleep(100)
        :cowboy_req.stream_body(<<0>>, :nofin, req)
      end)
    end
  end

  @guests [
    {"vhostileundecodable", :undecodable},
    {"vhostilebadtrailer", :bad_trailer},
    {"vhostiletrickle", :trickle}
  ]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:cowboy)
    original = Hyper.Cfg.Toml.reload()
    tmp = Path.join(System.tmp_dir!(), "agent-hostile-#{System.unique_integer([:positive])}")
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    File.mkdir_p!(Hyper.Cfg.Dirs.socket_dir())

    for {id, mode} <- @guests do
      dispatch = :cowboy_router.compile([{:_, [{:_, Guest, mode}]}])

      {:ok, _} =
        :cowboy.start_clear(
          {__MODULE__, id},
          [ip: {:local, Agent.relay_socket_path(id)}, port: 0],
          %{env: %{dispatch: dispatch}, protocols: [:http2]}
        )
    end

    on_exit(fn ->
      for {id, _} <- @guests, do: :cowboy.stop_listener({__MODULE__, id})
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf(tmp)
    end)

    :ok
  end

  test "a hostile reply ends the call within the deadline as an error, and closes the connection" do
    rows = [
      {"vhostileundecodable", &match?({:error, {:bad_agent_reply, _}}, &1)},
      {"vhostilebadtrailer", &match?({:error, {:bad_agent_reply, _}}, &1)},
      {"vhostiletrickle", &(&1 == {:error, :timeout})}
    ]

    for {id, expected?} <- rows do
      before = connections()

      {elapsed_us, result} =
        :timer.tc(fn -> Agent.exec(id, ["/bin/sync"], timeout: @deadline_ms) end)

      assert expected?.(result), "#{id}: #{inspect(result)}"
      assert elapsed_us < (@deadline_ms + 1_000) * 1_000, "#{id} took #{elapsed_us}us"
      assert closed_back_to?(before), "#{id} left its connection open"
    end
  end

  test "a reply larger than the relay cap ends the call as an error instead of being buffered" do
    id = "vhostileflood"
    guest_path = Path.join(Hyper.Cfg.Dirs.socket_dir(), "guest-#{id}.sock")
    vsock_path = Path.join(Hyper.Cfg.Dirs.socket_dir(), "vsock-#{id}.sock")
    dispatch = :cowboy_router.compile([{:_, [{:_, Guest, :flood}]}])

    {:ok, _} =
      :cowboy.start_clear(
        {__MODULE__, id},
        [ip: {:local, guest_path}, port: 0],
        %{env: %{dispatch: dispatch}, protocols: [:http2]}
      )

    on_exit(fn -> :cowboy.stop_listener({__MODULE__, id}) end)

    {:ok, fc} = :socket.open(:local, :stream)
    :ok = :socket.bind(fc, %{family: :local, path: vsock_path})
    :ok = :socket.listen(fc, 1)
    _ = spawn_link(fn -> fake_firecracker(fc, guest_path) end)

    start_supervised!(
      {Relay, %{vm_id: id, vsock_uds: vsock_path, listen_path: Agent.relay_socket_path(id)}}
    )

    before = connections()

    {elapsed_us, result} =
      :timer.tc(fn -> Agent.exec(id, ["/bin/cat"], timeout: @flood_deadline_ms) end)

    assert {:error, reason} = result
    assert reason != :timeout
    assert elapsed_us < @flood_deadline_ms * 1_000, "flood took #{elapsed_us}us"
    assert closed_back_to?(before), "flood left its connection open"
  end

  defp fake_firecracker(listen, guest_path) do
    {:ok, vsock} = :socket.accept(listen)
    {:ok, "CONNECT " <> _} = :socket.recv(vsock)
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
    end
  end

  defp closed_back_to?(count, tries \\ 100)
  defp closed_back_to?(count, 0), do: connections() <= count

  defp closed_back_to?(count, tries) do
    connections() <= count or
      (
        Process.sleep(10)
        closed_back_to?(count, tries - 1)
      )
  end

  defp connections,
    do:
      length(DynamicSupervisor.which_children(GRPC.Client.Supervisor)) +
        length(Supervisor.which_children(:gun_conns_sup))
end
