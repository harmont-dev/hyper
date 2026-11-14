defmodule Hyper.Node.FireVMM.AgentSecurityTest do
  @moduledoc """
  `Agent.exec/3` against a hostile guest agent (#132). Whatever bytes the guest
  answers with — wrong HTTP status, wrong content type, gRPC frames whose
  declared length lies, a set compression flag nobody negotiated, non-numeric
  or out-of-range `grpc-status`, a stream that ends without trailers, or one
  that never ends — the call:

  - **is total** — it returns `{:ok, %{stdout: binary, stderr: binary,
    exit_code: integer}}` or `{:error, _}`, and never raises, throws or exits
    into the caller;
  - **is bounded by its deadline** — it returns within `:timeout` plus slack;
  - **leaves nothing behind** — no stray message in the caller, no gRPC
    connection process.

  And independent of the reply:

  - a caller killed mid-call does not leak its gRPC connection, and the guest
    sees its connection closed;
  - a timed-out call through the real relay closes the guest-side (vsock)
    connection, so a silent guest cannot accumulate host-held connections;
  - a well-formed status-0 reply is decoded exactly, and a caller that traps
    exits is left no stray `:EXIT` message by it;
  - a relay whose guest is not (yet) listening, or answers the vsock CONNECT
    with garbage, is `:agent_unavailable` within the deadline.

  `async: false`: `Hyper.Cfg.Toml.put_cache/1` is process-global.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Agent.V1.ExecResponse
  alias Hyper.Node.FireVMM.Agent
  alias Hyper.Node.FireVMM.Agent.Relay

  @slack_ms 1_000
  @fuzz_id "vhostilefuzz"

  defmodule Guest do
    @moduledoc false

    def init(req, id) do
      script = :persistent_term.get({__MODULE__, id})
      send(script.test, {:guest_request, self()})
      {:ok, _body, req} = :cowboy_req.read_body(req)
      req = :cowboy_req.stream_reply(script.status, %{"content-type" => script.ctype}, req)
      Enum.each(script.frames, &:cowboy_req.stream_body(&1, :nofin, req))
      finish(script.finish, req)
      {:ok, req, id}
    end

    defp finish({:trailers, trailers}, req), do: :cowboy_req.stream_trailers(trailers, req)
    defp finish(:fin, req), do: :cowboy_req.stream_body("", :fin, req)
    defp finish(:hang, _req), do: Process.sleep(:infinity)
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:cowboy)
    original = Hyper.Cfg.Toml.reload()
    tmp = Path.join(System.tmp_dir!(), "agent-sec-#{System.unique_integer([:positive])}")
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))
    File.mkdir_p!(Hyper.Cfg.Dirs.socket_dir())

    dispatch = :cowboy_router.compile([{:_, [{:_, Guest, @fuzz_id}]}])

    {:ok, _} =
      :cowboy.start_clear(
        {__MODULE__, @fuzz_id},
        [ip: {:local, Agent.relay_socket_path(@fuzz_id)}, port: 0],
        %{env: %{dispatch: dispatch}, protocols: [:http2]}
      )

    on_exit(fn ->
      :cowboy.stop_listener({__MODULE__, @fuzz_id})
      :persistent_term.erase({Guest, @fuzz_id})
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf(tmp)
    end)

    :ok
  end

  defp script(fields), do: :persistent_term.put({Guest, @fuzz_id}, Map.put(fields, :test, self()))

  defp grpc_frame do
    gen all(
          flag <- one_of([constant(0), constant(1), integer(2..255)]),
          payload <- binary(max_length: 256),
          declared <-
            one_of([
              constant(byte_size(payload)),
              integer(0..0xFFFF_FFFF),
              constant(0xFFFF_FFFF)
            ])
        ) do
      <<flag, declared::32, payload::binary>>
    end
  end

  defp grpc_status do
    one_of([
      constant("0"),
      member_of(["1", "4", "13", "14", "16"]),
      member_of(["abc", "-1", "", " 0", "0x0", "99999999999999999999999", "1e3"]),
      string(:printable, max_length: 16)
    ])
  end

  defp finish do
    one_of([
      gen all(
            status <- grpc_status(),
            message <- string(:printable, max_length: 64),
            drop_status? <- boolean()
          ) do
        trailers = %{"grpc-message" => message}

        {:trailers,
         if(drop_status?, do: trailers, else: Map.put(trailers, "grpc-status", status))}
      end,
      constant(:fin),
      constant(:hang)
    ])
  end

  defp hostile_reply do
    gen all(
          status <- member_of([200, 200, 200, 204, 400, 404, 500, 503]),
          ctype <-
            member_of(["application/grpc", "application/grpc+proto", "text/html", "", "x/y"]),
          frames <- list_of(grpc_frame(), max_length: 4),
          finish <- finish()
        ) do
      %{status: status, ctype: ctype, frames: frames, finish: finish}
    end
  end

  defp isolated_exec(id, opts, trap? \\ false) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, trap?)
        {us, result} = :timer.tc(fn -> Agent.exec(id, ["/bin/true"], opts) end)
        Process.sleep(100)
        {:messages, stray} = Process.info(self(), :messages)
        send(parent, {:exec_done, self(), us, result, stray})
      end)

    receive do
      {:exec_done, ^pid, us, result, stray} ->
        Process.demonitor(ref, [:flush])
        {:returned, us, result, stray}

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:caller_died, reason}
    after
      Keyword.fetch!(opts, :timeout) + 10_000 -> {:caller_hung, pid}
    end
  end

  defp well_formed?({:ok, %{stdout: out, stderr: err, exit_code: code}}),
    do: is_binary(out) and is_binary(err) and is_integer(code)

  defp well_formed?({:error, _}), do: true
  defp well_formed?(_), do: false

  property "any hostile reply is a well-formed result within the deadline, leaving nothing behind" do
    check all(reply <- hostile_reply(), deadline_ms <- integer(150..400), max_runs: 60) do
      script(reply)
      before = connections()

      outcome = isolated_exec(@fuzz_id, timeout: deadline_ms)

      assert {:returned, us, result, stray} = outcome,
             "caller did not return: #{inspect(outcome)}"

      assert well_formed?(result), "ill-formed result #{inspect(result)} for #{inspect(reply)}"
      assert us < (deadline_ms + @slack_ms) * 1_000, "took #{div(us, 1_000)}ms: #{inspect(reply)}"
      assert stray == [], "left #{inspect(stray)} in the caller for #{inspect(reply)}"
      assert closed_back_to?(before), "left a gRPC connection for #{inspect(reply)}"
    end
  end

  test "a well-formed status-0 reply decodes exactly" do
    resp = %ExecResponse{exit_code: 42, stdout: <<0, 255, "out">>, stderr: "err\n"}
    msg = ExecResponse.encode(resp)

    script(%{
      status: 200,
      ctype: "application/grpc",
      frames: [<<0, byte_size(msg)::32, msg::binary>>],
      finish: {:trailers, %{"grpc-status" => "0"}}
    })

    assert {:returned, _us, {:ok, %{exit_code: 42, stdout: <<0, 255, "out">>, stderr: "err\n"}},
            []} = isolated_exec(@fuzz_id, timeout: 2_000)
  end

  test "a caller that traps exits is left no stray message by a successful call" do
    msg = ExecResponse.encode(%ExecResponse{exit_code: 0, stdout: "ok"})

    script(%{
      status: 200,
      ctype: "application/grpc",
      frames: [<<0, byte_size(msg)::32, msg::binary>>],
      finish: {:trailers, %{"grpc-status" => "0"}}
    })

    assert {:returned, _us, {:ok, %{stdout: "ok"}}, stray} =
             isolated_exec(@fuzz_id, [timeout: 2_000], true)

    assert stray == []
  end

  test "a zero deadline times out at once without leaking a connection" do
    script(%{status: 200, ctype: "application/grpc", frames: [], finish: :hang})
    before = connections()

    assert {:returned, us, {:error, :timeout}, []} = isolated_exec(@fuzz_id, timeout: 0)
    assert us < @slack_ms * 1_000
    assert closed_back_to?(before)
  end

  test "a caller killed mid-call does not leak its gRPC connection" do
    script(%{status: 200, ctype: "application/grpc", frames: [], finish: :hang})
    before = connections()

    caller = spawn(fn -> Agent.exec(@fuzz_id, ["/bin/true"], timeout: 60_000) end)
    assert_receive {:guest_request, handler}, 5_000
    handler_ref = Process.monitor(handler)
    Process.exit(caller, :kill)

    assert closed_back_to?(before),
           "killed caller left #{connections() - before} gRPC connection(s) behind"

    assert_receive {:DOWN, ^handler_ref, :process, ^handler, _}, 5_000
  end

  describe "through the real relay" do
    setup do
      id = "vsecrelay#{System.unique_integer([:positive])}"
      vsock_path = Path.join(Hyper.Cfg.Dirs.socket_dir(), "vsock-#{id}.sock")
      {:ok, fc} = :socket.open(:local, :stream)
      :ok = :socket.bind(fc, %{family: :local, path: vsock_path})
      :ok = :socket.listen(fc, 16)

      start_supervised!(
        {Relay, %{vm_id: id, vsock_uds: vsock_path, listen_path: Agent.relay_socket_path(id)}}
      )

      on_exit(fn ->
        :socket.close(fc)
        File.rm(vsock_path)
      end)

      %{id: id, fc: fc}
    end

    test "a timed-out call closes the guest-side connection", %{id: id, fc: fc} do
      test = self()

      guests =
        for _ <- 1..4 do
          spawn(fn ->
            {:ok, conn} = :socket.accept(fc)
            {:ok, "CONNECT " <> _} = :socket.recv(conn, 0, 2_000)
            :ok = :socket.send(conn, "OK 5\n")
            send(test, {:guest_fate, self(), fate(conn)})
          end)
        end

      for _ <- guests do
        assert {:returned, _us, {:error, :timeout}, []} = isolated_exec(id, timeout: 200)
      end

      for g <- guests do
        assert_receive {:guest_fate, ^g, :closed}, @slack_ms * 3
      end
    end

    test "a guest that refuses the vsock CONNECT is :agent_unavailable, not a full-deadline timeout",
         %{id: id, fc: fc} do
      rows = [
        {"garbage CONNECT reply",
         fn ->
           spawn(fn ->
             {:ok, conn} = :socket.accept(fc)
             {:ok, _} = :socket.recv(conn, 0, 2_000)
             _ = :socket.send(conn, :binary.copy("A", 1_000_000))
             Process.sleep(:infinity)
           end)
         end},
        {"guest not listening yet", fn -> :ok = :socket.close(fc) end}
      ]

      for {label, guest} <- rows do
        guest.()
        before = connections()

        assert {:returned, us, result, []} = isolated_exec(id, timeout: 2_000)
        assert {label, result} == {label, {:error, :agent_unavailable}}
        assert us < 2_000_000, "#{label}: took #{div(us, 1_000)}ms, the whole deadline"
        assert closed_back_to?(before)
      end
    end
  end

  defp fate(conn) do
    case :socket.recv(conn, 0, 10_000) do
      {:ok, _} -> fate(conn)
      {:error, reason} -> reason
    end
  end

  defp closed_back_to?(count, tries \\ 200)
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
