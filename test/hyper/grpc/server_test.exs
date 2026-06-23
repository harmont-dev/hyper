defmodule Hyper.Grpc.ServerTest do
  use ExUnit.Case, async: false

  alias Hyper.Cluster.Routing
  alias Hyper.Grpc.V1.{GetMachineRequest, ListMachinesRequest, StopMachineRequest}
  alias Hyper.Grpc.V1.Machines.Stub

  @port 50_151

  setup do
    # Tests run with --no-start, so the OTP apps that the gRPC server stack
    # depends on (ranch → cowboy → grpc_server) need to be started manually.
    {:ok, _} = Application.ensure_all_started(:grpc_server)
    {:ok, _} = Application.ensure_all_started(:grpc)

    start_supervised!(Routing)

    start_supervised!(
      {GRPC.Server.Supervisor, endpoint: Hyper.Grpc.Endpoint, port: @port, start_server: true}
    )

    # The :gun dep is not included in this project; use the Mint adapter instead.
    {:ok, channel} =
      GRPC.Stub.connect("localhost:#{@port}", adapter: GRPC.Client.Adapters.Mint)

    %{channel: channel}
  end

  test "GetMachine on an unknown id returns NOT_FOUND", %{channel: channel} do
    assert {:error, %GRPC.RPCError{status: 5}} =
             Stub.get_machine(channel, %GetMachineRequest{vm_id: "nope"})
  end

  test "StopMachine on an unknown id returns NOT_FOUND", %{channel: channel} do
    assert {:error, %GRPC.RPCError{status: 5}} =
             Stub.stop_machine(channel, %StopMachineRequest{vm_id: "nope"})
  end

  test "ListMachines is empty when no VMs are registered", %{channel: channel} do
    assert {:ok, %{machines: []}} = Stub.list_machines(channel, %ListMachinesRequest{})
  end
end
