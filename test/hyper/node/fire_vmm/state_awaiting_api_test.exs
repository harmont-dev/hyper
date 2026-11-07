defmodule Hyper.Node.FireVMM.StateAwaitingApiTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Node.FireVMM.State
  alias Hyper.Node.FireVMM.State.AwaitingApi
  alias Hyper.Test.SuidHelperStub

  defmodule RefusingClient do
    @moduledoc false
    use GenServer

    def start_link(vm_id), do: GenServer.start_link(__MODULE__, vm_id)

    @impl true
    def init(vm_id) do
      :ok = Hyper.Cluster.Routing.register_self({vm_id, :client})
      {:ok, nil}
    end

    @impl true
    def handle_call({:run, _op_fun}, _from, state), do: {:reply, {:error, :eacces}, state}
  end

  setup do
    tmp = Path.join(System.tmp_dir!(), "awaiting-api-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    if reaper = Process.whereis(Hyper.Node.Reaper) do
      :ok = :sys.suspend(reaper)
      on_exit(fn -> :sys.resume(reaper) end)
    end

    unless Process.whereis(Hyper.Cluster.Routing) do
      _ = Application.ensure_all_started(:horde)
      start_supervised!(Hyper.Cluster.Routing)
    end

    %{tmp: tmp}
  end

  test "a probe that fails after a claim claims again on the next probe", %{tmp: tmp} do
    vm_id = Hyper.Vm.Id.generate()
    claims = Path.join(tmp, "claims")
    SuidHelperStub.install!(tmp, ~s(echo claim >> "#{claims}"; echo '{"result":"claimed"}'))
    start_supervised!({RefusingClient, vm_id})
    await_client(vm_id)

    data = %State{
      opts: %Opts{vm_id: vm_id},
      boot_deadline: System.monotonic_time(:millisecond) + 60_000
    }

    assert {:keep_state, data, _} = AwaitingApi.handle(:state_timeout, :probe, data)
    assert {:keep_state, _, _} = AwaitingApi.handle(:state_timeout, :probe, data)
    assert claims |> File.read!() |> String.split("\n", trim: true) |> length() == 2
  end

  defp await_client(vm_id, tries \\ 200)
  defp await_client(vm_id, 0), do: flunk("client stub for #{vm_id} never materialised")

  defp await_client(vm_id, tries) do
    case Horde.Registry.lookup(Hyper.Cluster.Routing.name(), {vm_id, :client}) do
      [] ->
        Process.sleep(5)
        await_client(vm_id, tries - 1)

      [_ | _] ->
        :ok
    end
  end
end
