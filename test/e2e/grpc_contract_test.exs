defmodule Hyper.E2e.GrpcContractTest do
  @moduledoc """
  Live contract test of the public gRPC surface (`hyper.grpc.v0.Hyper`),
  exercised from outside the BEAM: starts the gRPC server against the running
  app tree, then drives it with the TypeScript suite in `test/grpc/`, which
  loads `proto/hyper/grpc/v0/hyper.proto` directly. Status codes and the full
  VM lifecycle are asserted over the real wire, catching proto/codec/server
  drift a BEAM-side client cannot produce (e.g. unrecognised enum integers).

  Also carries one BEAM-side test of `ForkVm`: it needs a real booted parent
  VM (Firecracker + device-mapper), which the TypeScript suite cannot boot,
  so it drives `Hyper.Grpc.V0.Hyper.Stub` directly over the same server
  instead.

  Runs only under `--only integration` on a provisioned host (CI: the
  `integration` job). Requires node/npm on PATH; installs the suite's npm
  deps on first run.
  """
  use ExUnit.Case, async: false

  alias Hyper.Grpc.V0.{ForkVmRequest, ForkVmResponse, StopVmRequest}
  alias Hyper.Grpc.V0.Hyper.Stub

  @moduletag :integration
  @moduletag timeout: :timer.minutes(25)

  @port 50_061
  @suite_dir Path.expand("../grpc", __DIR__)

  # public.ecr.aws mirrors library images without Docker Hub's per-IP pull
  # limits, which shared GHA egress IPs routinely exhaust.
  @image System.get_env("HYPER_E2E_IMAGE", "public.ecr.aws/docker/library/alpine:3.19")

  setup_all do
    config = %Hyper.Cfg.Grpc{enabled: true, port: @port}
    start_supervised!({GRPC.Server.Supervisor, Hyper.Cfg.Grpc.server_options(config)})
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{@port}", adapter: GRPC.Client.Adapters.Gun)
    {:ok, channel: channel}
  end

  test "TypeScript contract suite passes against the live server" do
    ensure_node_deps!()

    {_streamed, status} =
      System.cmd("npm", ["test"],
        cd: @suite_dir,
        env: [{"HYPER_GRPC_ADDR", "127.0.0.1:#{@port}"}],
        stderr_to_stdout: true,
        into: IO.stream()
      )

    assert status == 0, "TypeScript gRPC contract suite failed (exit #{status}); see output above"
  end

  test "ForkVm boots a distinct child from a running parent", %{channel: channel} do
    assert {:ok, img_id} = Hyper.Img.OciLoader.load(@image)

    assert {:ok, parent} = Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: :micro})
    on_exit(fn -> Hyper.Node.stop_image_vm(parent) end)

    parent_id = Hyper.id(parent)
    assert parent_id, "Hyper.id/1 returned nil for a freshly-created VM"

    assert {:ok, %ForkVmResponse{vm_id: child_id, node: child_node}} =
             Stub.fork_vm(channel, %ForkVmRequest{vm_id: parent_id})

    assert is_binary(child_id) and child_id != parent_id
    assert child_node != ""

    on_exit(fn -> Stub.stop_vm(channel, %StopVmRequest{vm_id: child_id}) end)
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
      (test/grpc) needs Node.js and npm on PATH.
      """)
  end
end
