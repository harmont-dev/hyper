defmodule Hyper.Node.FireVMM.AgentHostileTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.FireVMM.Agent

  @deadline_ms 500

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

  defp closed_back_to?(count, tries \\ 100)
  defp closed_back_to?(count, 0), do: connections() <= count

  defp closed_back_to?(count, tries) do
    connections() <= count or
      (
        Process.sleep(10)
        closed_back_to?(count, tries - 1)
      )
  end

  defp connections, do: length(DynamicSupervisor.which_children(GRPC.Client.Supervisor))
end
