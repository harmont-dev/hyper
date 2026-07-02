defmodule Hyper.Node.FireVMM.AgentTest do
  @moduledoc """
  Tests for `Hyper.Node.FireVMM.Agent`.

  Invariants exercised:

  - `relay_socket_path/1` returns an absolute, deterministic path whose
    filename contains the vm_id.
  - `exec/3` encodes argv, env, and cwd into the gRPC request correctly:
    the test server reflects env and cwd back in its response so we can
    assert they arrived as built.
  - Exit code 127 is a successful exec (the guest returned 127), not an error.
  - Error mapping: gRPC UNAVAILABLE → `:agent_unavailable`;
    DEADLINE_EXCEEDED → `:timeout`.

  The gRPC server runs in-process (cowboy + Gun over a Unix socket), so these
  tests need neither a running VM nor the Rust guest-agent binary.

  `async: false` because `Hyper.Cfg.Toml.put_cache/1` writes to
  `:persistent_term`, which is process-global state.
  """

  use ExUnit.Case, async: false

  alias Hyper.Agent.V1.{ExecResponse, HealthResponse}
  alias Hyper.Node.FireVMM.Agent

  @test_vm_id "vtest000000000000"

  defmodule TestGuestAgentServer do
    @moduledoc false
    use GRPC.Server, service: Hyper.Agent.V1.GuestAgent.Service

    def exec(%{argv: ["/bin/echo", "hi"]}, _stream) do
      %ExecResponse{exit_code: 0, stdout: "hi\n", stderr: ""}
    end

    def exec(%{argv: ["missing-cmd"]}, _stream) do
      %ExecResponse{exit_code: 127, stdout: "", stderr: "missing-cmd: command not found\n"}
    end

    # Reflects env and cwd from the received request so the caller can prove
    # the client built the ExecRequest fields correctly.
    def exec(%{argv: ["reflect-request"]} = req, _stream) do
      env_str =
        req.env
        |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
        |> Enum.sort()
        |> Enum.join(",")

      cwd_str = req.cwd || ""
      %ExecResponse{exit_code: 0, stdout: "env=#{env_str} cwd=#{cwd_str}", stderr: ""}
    end

    def exec(%{argv: ["raise-unavailable"]}, _stream) do
      raise GRPC.RPCError, status: :unavailable, message: "simulated unavailable"
    end

    def exec(%{argv: ["raise-deadline"]}, _stream) do
      raise GRPC.RPCError, status: :deadline_exceeded, message: "simulated deadline"
    end

    def health(_req, _stream) do
      %HealthResponse{ok: true}
    end
  end

  setup_all do
    # --no-start mode: ensure the gRPC client and server runtimes are started.
    {:ok, _} = Application.ensure_all_started(:grpc)
    {:ok, _} = Application.ensure_all_started(:cowboy)

    # Redirect socket_dir to a writable tmp path for this test run.
    # We save the original cache (empty in CI since /etc/hyper/config.toml is
    # absent) and restore it when the module exits.
    original_cache = Hyper.Cfg.Toml.reload()
    :ok = Hyper.Cfg.Toml.put_cache(Map.put(original_cache, "work_dir", System.tmp_dir!()))

    socket_dir = Hyper.Cfg.Dirs.socket_dir()
    File.mkdir_p!(socket_dir)

    socket_path = Agent.relay_socket_path(@test_vm_id)
    File.rm(socket_path)

    {:ok, _pid, _port} =
      GRPC.Server.start(TestGuestAgentServer, 0, adapter_opts: [ip: {:local, socket_path}])

    on_exit(fn ->
      GRPC.Server.stop(TestGuestAgentServer)
      File.rm(socket_path)
      Hyper.Cfg.Toml.put_cache(original_cache)
    end)

    :ok
  end

  describe "relay_socket_path/1" do
    test "returns an absolute path" do
      path = Agent.relay_socket_path(@test_vm_id)
      assert Path.type(path) == :absolute
    end

    test "path filename contains the vm_id" do
      path = Agent.relay_socket_path(@test_vm_id)
      assert String.contains?(Path.basename(path), @test_vm_id)
    end

    test "is deterministic: same input produces the same path" do
      assert Agent.relay_socket_path(@test_vm_id) == Agent.relay_socket_path(@test_vm_id)
    end

    test "different vm_ids produce different paths" do
      assert Agent.relay_socket_path(@test_vm_id) != Agent.relay_socket_path("vother0000000000")
    end
  end

  describe "exec/3 — response mapping" do
    test "happy path: returns stdout/stderr/exit_code" do
      assert {:ok, %{exit_code: 0, stdout: "hi\n", stderr: ""}} =
               Agent.exec(@test_vm_id, ["/bin/echo", "hi"], [])
    end

    test "exit code 127 is a successful exec, not an error" do
      assert {:ok, %{exit_code: 127, stdout: "", stderr: _}} =
               Agent.exec(@test_vm_id, ["missing-cmd"], [])
    end
  end

  describe "exec/3 — request-building" do
    test "env and cwd are forwarded to the server" do
      # The reflect-request handler echoes env+cwd from the received ExecRequest,
      # so a correct response proves the client built and sent the fields.
      assert {:ok, %{exit_code: 0, stdout: stdout}} =
               Agent.exec(
                 @test_vm_id,
                 ["reflect-request"],
                 env: %{"FRUIT" => "mango", "COLOR" => "blue"},
                 cwd: "/workspace"
               )

      assert String.contains?(stdout, "COLOR=blue")
      assert String.contains?(stdout, "FRUIT=mango")
      assert String.contains?(stdout, "cwd=/workspace")
    end

    test "absent env and cwd are sent as empty/nil" do
      assert {:ok, %{exit_code: 0, stdout: stdout}} =
               Agent.exec(@test_vm_id, ["reflect-request"], [])

      assert String.contains?(stdout, "env=")
      assert String.contains?(stdout, "cwd=")
      refute String.contains?(stdout, "=mango")
    end
  end

  describe "exec/3 — error mapping" do
    test "gRPC UNAVAILABLE maps to :agent_unavailable" do
      assert {:error, :agent_unavailable} =
               Agent.exec(@test_vm_id, ["raise-unavailable"], [])
    end

    test "gRPC DEADLINE_EXCEEDED maps to :timeout" do
      assert {:error, :timeout} =
               Agent.exec(@test_vm_id, ["raise-deadline"], [])
    end

    test "returns {:error, _} when no server is listening at the relay path" do
      dead_id = "vdead0000000000000"
      # No server at this path; connect or the RPC itself fails.
      assert {:error, _} = Agent.exec(dead_id, ["/bin/echo", "nope"], timeout: 500)
    end
  end
end
