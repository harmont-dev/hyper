defmodule Hyper.E2e.GrpcContractTest do
  @moduledoc """
  Live contract test of the public gRPC surface (`hyper.grpc.v0.Hyper`),
  exercised from outside the BEAM: starts the gRPC server against the running
  app tree, then drives it with the TypeScript suite in `test/grpc/`, which
  loads `proto/hyper/grpc/v0/hyper.proto` directly. Status codes and the full
  VM lifecycle are asserted over the real wire, catching proto/codec/server
  drift a BEAM-side client cannot produce (e.g. unrecognised enum integers).

  Runs only under `--only integration` on a provisioned host (CI: the
  `integration` job). Requires node/npm on PATH; installs the suite's npm
  deps on first run.
  """
  use ExUnit.Case, async: false

  @moduletag :integration
  @moduletag timeout: :timer.minutes(30)

  @port 50_061
  @suite_dir Path.expand("../grpc", __DIR__)

  setup_all do
    config = %Hyper.Cfg.Grpc{enabled: true, port: @port}
    start_supervised!({GRPC.Server.Supervisor, Hyper.Cfg.Grpc.server_options(config)})
    :ok
  end

  test "TypeScript contract suite passes against the live server" do
    ensure_node_deps!()

    {out, status} =
      System.cmd("npm", ["test"],
        cd: @suite_dir,
        env: [{"HYPER_GRPC_ADDR", "127.0.0.1:#{@port}"}],
        stderr_to_stdout: true
      )

    IO.write(out)
    assert status == 0, "TypeScript gRPC contract suite failed (exit #{status}); see output above"
  end

  defp ensure_node_deps! do
    if not File.dir?(Path.join(@suite_dir, "node_modules")) do
      {out, status} = System.cmd("npm", ["ci"], cd: @suite_dir, stderr_to_stdout: true)
      assert status == 0, "npm ci failed in #{@suite_dir}:\n#{out}"
    end
  rescue
    e in ErlangError ->
      flunk("""
      npm is unavailable (#{inspect(e.original)}). The gRPC contract suite
      needs Node.js and npm on PATH — see test/grpc/README.md.
      """)
  end
end
