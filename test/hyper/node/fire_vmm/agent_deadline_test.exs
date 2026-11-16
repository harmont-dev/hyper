defmodule Hyper.Node.FireVMM.AgentDeadlineTest do
  @moduledoc """
  `Agent.exec/3`'s `:timeout` is the deadline for the *whole* call (#132):

  - an unreachable relay (no socket file, or a stale one nobody listens on)
    is `{:error, :agent_unavailable}`, decided within the deadline rather than
    after the transport's own connect retries;
  - a relay that accepts and never answers is `{:error, :timeout}`, returned
    no earlier than the deadline and no later than the deadline plus slack;
  - whatever the outcome, the call leaves nothing behind in the caller: no
    stray message in its mailbox (even when it traps exits) and no gRPC
    connection process.

  `async: false`: `Hyper.Cfg.Toml.put_cache/1` is process-global.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Agent.V1.ExecResponse
  alias Hyper.Node.FireVMM.Agent

  @slack_ms 1_000

  defmodule Echo do
    @moduledoc false
    use GRPC.Server, service: Hyper.Agent.V1.GuestAgent.Service

    def exec(%{argv: ["/bin/echo" | rest]}, _stream),
      do: %ExecResponse{exit_code: 0, stdout: Enum.join(rest, " ")}

    def health(_req, _stream), do: %Hyper.Agent.V1.HealthResponse{ok: true}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:cowboy)
    original = Hyper.Cfg.Toml.reload()
    tmp = Path.join(System.tmp_dir!(), "agent-deadline-#{System.unique_integer([:positive])}")
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    File.mkdir_p!(Hyper.Cfg.Dirs.socket_dir())

    {:ok, _pid, _port} =
      GRPC.Server.start(Echo, 0, adapter_opts: [ip: {:local, Agent.relay_socket_path("vecho")}])

    stale = Agent.relay_socket_path("vstale")
    {:ok, s} = :socket.open(:local, :stream)
    :ok = :socket.bind(s, %{family: :local, path: stale})
    :ok = :socket.close(s)
    true = File.exists?(stale)

    {:ok, silent} = :socket.open(:local, :stream)
    :ok = :socket.bind(silent, %{family: :local, path: Agent.relay_socket_path("vsilent")})
    :ok = :socket.listen(silent, 64)
    acceptor = spawn(fn -> accept_and_hold(silent, []) end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      GRPC.Server.stop(Echo)
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp accept_and_hold(listen, held) do
    case :socket.accept(listen) do
      {:ok, conn} -> accept_and_hold(listen, [conn | held])
      {:error, _} -> Process.sleep(:infinity)
    end
  end

  test "an unreachable relay is :agent_unavailable within the deadline" do
    deadline_ms = 300

    observed =
      for id <- ["vmissing", "vstale"] do
        {elapsed_us, result} =
          :timer.tc(fn -> Agent.exec(id, ["/bin/echo"], timeout: deadline_ms) end)

        {id, result, div(elapsed_us, 1_000) < deadline_ms + @slack_ms, div(elapsed_us, 1_000)}
      end

    assert Enum.map(observed, fn {id, result, in_time?, _ms} -> {id, result, in_time?} end) ==
             [
               {"vmissing", {:error, :agent_unavailable}, true},
               {"vstale", {:error, :agent_unavailable}, true}
             ],
           "observed (id, result, in_time?, ms): #{inspect(observed)}"
  end

  property "a silent relay times out at the deadline, never early and never much later" do
    check all(deadline_ms <- integer(50..600), max_runs: 6) do
      {elapsed_us, result} =
        :timer.tc(fn -> Agent.exec("vsilent", ["/bin/echo"], timeout: deadline_ms) end)

      assert result == {:error, :timeout}
      assert elapsed_us >= deadline_ms * 1_000, "returned early: #{elapsed_us}us"
      assert elapsed_us < (deadline_ms + @slack_ms) * 1_000, "late: #{elapsed_us}us"
    end
  end

  test "no outcome leaves a message in a caller that traps exits, nor a connection" do
    rows = [
      {"vecho", &(&1 == {:ok, %{exit_code: 0, stdout: "hi", stderr: ""}})},
      {"vsilent", &(&1 == {:error, :timeout})},
      {"vmissing", &match?({:error, _}, &1)}
    ]

    offenders =
      for {id, expected?} <- rows,
          {result, stray, closed?} = exec_in_trapping_caller(id),
          not (expected?.(result) and stray == [] and closed?),
          do: {id, result, stray, closed?}

    assert offenders == []
  end

  defp exec_in_trapping_caller(id) do
    before = connections()
    parent = self()

    spawn(fn ->
      Process.flag(:trap_exit, true)
      result = Agent.exec(id, ["/bin/echo", "hi"], timeout: 300)
      Process.sleep(200)
      {:messages, stray} = Process.info(self(), :messages)
      send(parent, {:done, result, stray})
    end)

    assert_receive {:done, result, stray}, 10_000
    {result, stray, closed_back_to?(before)}
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
