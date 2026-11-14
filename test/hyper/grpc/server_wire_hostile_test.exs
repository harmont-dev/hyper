defmodule Hyper.Grpc.ServerWireHostileTest do
  @moduledoc """
  Hostile clients against the real v1 gRPC server over the wire (cowboy + the
  generated service), where status codes are what an off-BEAM caller sees.

  Laws:

    * a request whose `string` field is not UTF-8 — a client free to put any
      bytes in the frame — is refused with a defined status (INVALID_ARGUMENT
      or INTERNAL, which v1 allows for any RPC), never UNKNOWN, and the server
      keeps answering well-formed calls afterwards;
    * an id that names nothing is NOT_FOUND on the wire for every
      vm_id-addressed RPC, whatever UTF-8 it carries (NUL included);
    * ListVms answers OK or INVALID_ARGUMENT for any page_size in int32 and
      any page_token string; the page never exceeds the documented maximum.
  """
  use ExUnit.Case, async: false

  alias Hyper.Grpc.V1.{
    GetVmRequest,
    GetVmUsageRequest,
    ListVmsRequest,
    ListVmsResponse,
    StopVmRequest
  }

  alias Hyper.Grpc.V1.Hyper.Stub

  @moduletag :external
  @moduletag :capture_log

  @port 50_071

  defmodule RawId do
    @moduledoc false
    use Protobuf, syntax: :proto3
    field(:vm_id, 1, type: :bytes)
  end

  defmodule RawService do
    @moduledoc false
    use GRPC.Service, name: "hyper.grpc.v1.Hyper"
    rpc(:GetVm, RawId, Hyper.Grpc.V1.GetVmResponse)
    rpc(:StopVm, RawId, Hyper.Grpc.V1.StopVmResponse)
    rpc(:GetVmUsage, RawId, Hyper.Grpc.V1.GetVmUsageResponse)
    rpc(:ForkVm, RawId, Hyper.Grpc.V1.ForkVmResponse)
  end

  defmodule RawStub do
    @moduledoc false
    use GRPC.Stub, service: RawService
  end

  setup_all do
    config = %Hyper.Cfg.Grpc{enabled: true, port: @port}
    start_supervised!({GRPC.Server.Supervisor, Hyper.Cfg.Grpc.server_options(config)})
    {:ok, channel} = GRPC.Stub.connect("127.0.0.1:#{@port}", adapter: GRPC.Client.Adapters.Gun)
    {:ok, channel: channel}
  end

  defp status({:error, %GRPC.RPCError{status: status}}), do: status
  defp status({:ok, _}), do: GRPC.Status.ok()

  test "non-UTF-8 bytes in a string field get a defined refusal, and the server keeps serving",
       %{channel: channel} do
    defined = [GRPC.Status.invalid_argument(), GRPC.Status.internal()]

    answers =
      for bytes <- [<<0xFF>>, <<0xC0, 0x80>>, <<0xED, 0xA0, 0x80>>, "v" <> <<0xFE>>],
          rpc <- [:get_vm, :stop_vm, :get_vm_usage, :fork_vm] do
        {rpc, bytes, status(apply(RawStub, rpc, [channel, %RawId{vm_id: bytes}]))}
      end

    assert status(Stub.get_vm(channel, %GetVmRequest{vm_id: "vabsent"})) ==
             GRPC.Status.not_found()

    assert Enum.reject(answers, fn {_rpc, _bytes, got} -> got in defined end) == []
  end

  test "an id naming nothing is NOT_FOUND on the wire for every vm_id-addressed RPC",
       %{channel: channel} do
    calls = [
      get_vm: &Stub.get_vm(channel, %GetVmRequest{vm_id: &1}),
      stop_vm: &Stub.stop_vm(channel, %StopVmRequest{vm_id: &1}),
      get_vm_usage: &Stub.get_vm_usage(channel, %GetVmUsageRequest{vm_id: &1})
    ]

    for vm_id <- ["", "v\0", <<0>>, "vabc\0def", String.duplicate("v", 65_536)],
        {rpc, call} <- calls do
      assert status(call.(vm_id)) == GRPC.Status.not_found(),
             "#{rpc}(#{inspect(vm_id, printable_limit: 24)}) must be NOT_FOUND on the wire"
    end
  end

  test "ListVms answers OK or INVALID_ARGUMENT for extreme sizes and arbitrary tokens",
       %{channel: channel} do
    sizes = [-2_147_483_648, -1, 0, 1, 1_001, 2_147_483_647]
    tokens = ["", "!!!!", "AA", "____", "\0", String.duplicate("A", 100_000), "AAAA===="]

    for size <- sizes, token <- tokens do
      case Stub.list_vms(channel, %ListVmsRequest{page_size: size, page_token: token}) do
        {:ok, %ListVmsResponse{vms: vms}} ->
          assert length(vms) <= Hyper.Grpc.Pageable.Vm.max_page_size()

        other ->
          assert status(other) == GRPC.Status.invalid_argument(),
                 "list_vms(#{size}, #{inspect(token, printable_limit: 16)}) answered #{inspect(other)}"
      end
    end
  end
end
