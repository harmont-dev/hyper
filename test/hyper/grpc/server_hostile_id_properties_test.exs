defmodule Hyper.Grpc.ServerHostileIdPropertiesTest do
  @moduledoc """
  Refusal contract of the v1 gRPC handlers (`Hyper.Grpc.Server`) for ids the
  client chooses. The wire decoder only guarantees a `string` field is valid
  UTF-8, so every other byte — NUL, control characters, megabyte-long ids,
  lookalikes of a minted `Hyper.Vm.Id` — reaches the handler.

  Laws:

    * for any client-chosen `vm_id` naming no VM, every vm_id-addressed RPC
      (GetVm, StopVm, ForkVm, SetVmFirewall, GetVmUsage) answers exactly the
      status v1 documents for it, NOT_FOUND — never a different status and never
      an escaped exception (which the transport turns into UNKNOWN);
    * for any client-chosen `img_id` naming no image, CreateVm answers NOT_FOUND
      ("no such image") and boots nothing.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Grpc.Server

  alias Hyper.Grpc.V1.{
    CreateVmRequest,
    Firewall,
    ForkVmRequest,
    GetVmRequest,
    GetVmUsageRequest,
    SetVmFirewallRequest,
    StopVmRequest
  }

  @moduletag :capture_log

  @not_found GRPC.Status.not_found()

  setup do
    unless Process.whereis(Hyper.Cluster.Routing) do
      _ = Application.ensure_all_started(:horde)
      start_supervised!(Hyper.Cluster.Routing)
    end

    :ok
  end

  defp hostile_id do
    one_of([
      string(:utf8, max_length: 64),
      string(:ascii, max_length: 64),
      map(string([?a..?z, ?2..?7], length: 16), &("v" <> &1)),
      map(string(:utf8, max_length: 16), &(&1 <> <<0>> <> &1)),
      map(integer(1..4), &String.duplicate("v", &1 * 262_144)),
      member_of(["", "*", "%", "_", "\\", "' OR '1'='1", "../../etc", "v\n", "v\0"])
    ])
  end

  defp status_of(fun) do
    fun.()
    :answered
  rescue
    e in GRPC.RPCError -> e.status
    e -> {:escaped, e.__struct__}
  catch
    kind, reason -> {:escaped, kind, reason}
  end

  defp vm_rpcs(vm_id) do
    [
      get_vm: fn -> Server.get_vm(%GetVmRequest{vm_id: vm_id}, nil) end,
      stop_vm: fn -> Server.stop_vm(%StopVmRequest{vm_id: vm_id}, nil) end,
      fork_vm: fn -> Server.fork_vm(%ForkVmRequest{vm_id: vm_id}, nil) end,
      set_vm_firewall: fn ->
        Server.set_vm_firewall(%SetVmFirewallRequest{vm_id: vm_id, firewall: %Firewall{}}, nil)
      end
    ]
  end

  property "every vm_id-addressed RPC answers NOT_FOUND for any id naming no VM" do
    check all(vm_id <- hostile_id(), Hyper.whereis(vm_id) == nil, max_runs: 200) do
      for {rpc, call} <- vm_rpcs(vm_id) do
        assert status_of(call) == @not_found,
               "#{rpc}(#{inspect(vm_id, limit: 8, printable_limit: 40)}) must answer NOT_FOUND"
      end
    end
  end

  @tag :external
  property "GetVmUsage answers NOT_FOUND for any id never metered" do
    check all(vm_id <- hostile_id(), Hyper.whereis(vm_id) == nil, max_runs: 200) do
      call = fn -> Server.get_vm_usage(%GetVmUsageRequest{vm_id: vm_id}, nil) end

      assert status_of(call) == @not_found,
             "get_vm_usage(#{inspect(vm_id, limit: 8, printable_limit: 40)}) must answer NOT_FOUND"
    end
  end

  @tag :external
  property "CreateVm answers NOT_FOUND for any img_id naming no image, booting nothing" do
    check all(img_id <- filter(hostile_id(), &(&1 != "")), max_runs: 200) do
      before = Hyper.Cluster.Routing.all()

      call = fn ->
        Server.create_vm(
          %CreateVmRequest{
            img_id: img_id,
            instance_type: :INSTANCE_TYPE_MICRO,
            arch: :ARCHITECTURE_X86_64
          },
          nil
        )
      end

      assert status_of(call) == @not_found,
             "create_vm(img_id: #{inspect(img_id, limit: 8, printable_limit: 40)}) must answer NOT_FOUND"

      assert Hyper.Cluster.Routing.all() == before
    end
  end
end
