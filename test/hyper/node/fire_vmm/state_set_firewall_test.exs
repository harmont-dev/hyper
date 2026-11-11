defmodule Hyper.Node.FireVMM.StateSetFirewallTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Node.FireVMM.Policy
  alias Hyper.Node.FireVMM.State
  alias Hyper.Test.SuidHelperStub
  alias Hyper.Vm.Firewall

  setup do
    tmp = Path.join(System.tmp_dir!(), "set-firewall-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    if reaper = Process.whereis(Hyper.Node.Reaper) do
      :ok = :sys.suspend(reaper)
      on_exit(fn -> :sys.resume(reaper) end)
    end

    unless Process.whereis(Policy.registry()) do
      start_supervised!({Registry, keys: :unique, name: Policy.registry()})
    end

    vm_id = Hyper.Vm.Id.generate()
    start_supervised!({Policy, %Opts{vm_id: vm_id, firewall: Firewall.default()}})
    {:ok, ssh} = Firewall.new([{:tcp, 22..22//1}], [])

    %{tmp: tmp, calls: Path.join(tmp, "calls"), vm_id: vm_id, ssh: ssh}
  end

  test "a policy is applied and recorded only once the jailer is up",
       %{tmp: tmp, calls: calls, vm_id: vm_id, ssh: ssh} do
    SuidHelperStub.install!(tmp, ~s(echo "$1" >> "#{calls}"; echo '{}'))

    rows = [
      {:awaiting_api, {:error, :not_ready}, Firewall.default(), 0},
      {:stopping, {:error, :stopping}, Firewall.default(), 0},
      {:configuring, :ok, ssh, 1},
      {:running, :ok, ssh, 1}
    ]

    for {state, reply, policy, applied} <- rows do
      :ok = Policy.put(vm_id, Firewall.default())
      File.rm(calls)

      assert set_firewall(state, vm_id, ssh) == reply, inspect(state)
      assert Policy.current(vm_id) == policy, inspect(state)
      assert length(read_calls(calls)) == applied, inspect(state)
    end
  end

  test "a policy the helper refuses is not recorded",
       %{tmp: tmp, vm_id: vm_id, ssh: ssh} do
    SuidHelperStub.install!(tmp, "echo boom >&2; exit 3")

    for state <- [:configuring, :running] do
      assert {:error, _} = set_firewall(state, vm_id, ssh)
      assert Policy.current(vm_id) == Firewall.default(), inspect(state)
    end
  end

  defp set_firewall(state, vm_id, firewall) do
    from = {self(), make_ref()}
    data = %State{opts: %Opts{vm_id: vm_id}}

    {:keep_state_and_data, [{:reply, ^from, reply}]} =
      State.handle_event({:call, from}, {:set_firewall, firewall}, state, data)

    reply
  end

  defp read_calls(calls) do
    case File.read(calls) do
      {:ok, body} -> String.split(body, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end
end
