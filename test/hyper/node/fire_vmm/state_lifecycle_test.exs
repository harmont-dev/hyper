defmodule Hyper.Node.FireVMM.StateLifecycleTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.State
  alias Hyper.Test.FirecrackerRecordingClient, as: Rec

  defp data_with(respond) do
    me = self()
    run = fn op_fun -> op_fun.(client: Rec, recorder: me, respond: respond) end

    %State{
      id: 1,
      socket_path: "/tmp/x.socket",
      source: {:snapshot, "/snaps/v1"},
      type: :centi,
      binary: "jailer",
      args: [],
      run: run
    }
  end

  test "pause issues PATCH /vm Paused and moves to :paused" do
    data = data_with(fn _ -> :ok end)
    from = {self(), make_ref()}

    assert {:next_state, :paused, ^data, [{:reply, ^from, :ok}]} =
             State.running({:call, from}, :pause, data)

    assert_received {:fc_call, :patch, "/vm", %Hyper.Firecracker.Api.Vm{state: "Paused"}}
  end

  test "pause failure keeps state and replies the error" do
    data = data_with(fn _ -> {:error, {:api, 400, "no"}} end)
    from = {self(), make_ref()}

    assert {:keep_state_and_data, [{:reply, ^from, {:error, {:api, 400, "no"}}}]} =
             State.running({:call, from}, :pause, data)
  end

  test "resume issues PATCH /vm Resumed and moves to :running" do
    data = data_with(fn _ -> :ok end)
    from = {self(), make_ref()}

    assert {:next_state, :running, ^data, [{:reply, ^from, :ok}]} =
             State.paused({:call, from}, :resume, data)

    assert_received {:fc_call, :patch, "/vm", %Hyper.Firecracker.Api.Vm{state: "Resumed"}}
  end
end
