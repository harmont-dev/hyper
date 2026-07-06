defmodule Hyper.Node.FireVMM.StateConfiguringTest do
  # async: false — each test rebinds the global :hyper suidhelper tool path.
  use ExUnit.Case, async: false

  @moduledoc """
  The vsock-grant retry classification in `State.Configuring` — the contract
  that decides whether a boot advances, retries, or fails:

    * granted        -> InstanceStart is issued -> :running (and InstanceStart
                        is issued ONLY on grant success — the ordering contract);
    * pending        -> re-arm the :grant_vsock timer (firecracker hasn't
                        created the socket yet; never a boot failure);
    * hard error     -> also re-arm until the deadline (transient helper
                        failures must not kill a boot that could still succeed);
    * past deadline  -> stop with {:vsock_grant_timeout, reason}, surfacing the
                        last REAL reason rather than swallowing it.

  Driven end-to-end through the real seams: a stub helper script behind
  `Hyper.Cfg.Tools.suidhelper/0` (so `ChrootJail.grant_vsock/1` decodes the
  helper's literal wire JSON — the exact serde output of Rust `GrantOut`), and
  a stub Client GenServer registered under the real Horde `{vm_id, :client}`
  routing key.
  """

  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Node.FireVMM.State
  alias Hyper.Node.FireVMM.State.Configuring

  defmodule ClientStub do
    @moduledoc false
    use GenServer

    def start_link({vm_id, test_pid}),
      do: GenServer.start_link(__MODULE__, {vm_id, test_pid})

    @impl true
    def init({vm_id, test_pid}) do
      :ok = Hyper.Cluster.Routing.register_self({vm_id, :client})
      {:ok, test_pid}
    end

    @impl true
    def handle_call({:run, _op_fun}, _from, test_pid) do
      send(test_pid, :instance_start_requested)
      {:reply, :ok, test_pid}
    end
  end

  @granted_json ~S({"result":"granted"})
  @pending_json ~S({"result":"pending"})

  setup context do
    tmp = Path.join(System.tmp_dir!(), "cfg-vsock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    Map.put(context, :tmp, tmp)
  end

  test "granted: InstanceStart is issued and the VM advances to :running", %{tmp: tmp} do
    vm_id = Hyper.Vm.Id.generate()
    stub_helper!(tmp, "echo '#{@granted_json}'")
    start_supervised!({ClientStub, {vm_id, self()}})
    await_client(vm_id)

    result = Configuring.handle(:state_timeout, :grant_vsock, data(vm_id, 60_000))

    assert {:next_state, :running, _} = result
    assert_received :instance_start_requested
  end

  test "pending and hard errors before the deadline re-arm the grant timer", %{tmp: tmp} do
    # Two rows, one assertion shape: the classification (retry, not fail) is
    # the behavior; the concrete interval is a tunable, so only its presence
    # and target are pinned. No ClientStub is running, so an erroneous
    # InstanceStart attempt would crash the call — its absence is asserted
    # implicitly by the handler returning at all.
    rows = [
      {"pending", "echo '#{@pending_json}'"},
      {"hard error", "echo boom >&2; exit 3"}
    ]

    for {label, script} <- rows do
      vm_id = Hyper.Vm.Id.generate()
      stub_helper!(tmp, script)

      result = Configuring.handle(:state_timeout, :grant_vsock, data(vm_id, 60_000))

      assert {:keep_state, _, [{:state_timeout, ms, :grant_vsock}]} = result,
             "#{label}: expected a re-arm, got #{inspect(result)}"

      assert ms > 0, "#{label}: re-arm delay must be positive"
    end
  end

  test "a lapsed deadline stops the boot surfacing the last real reason", %{tmp: tmp} do
    # The surfaced reason distinguishes "socket never appeared" from "the
    # grant itself kept failing (exit 3, stderr text)" — the diagnostic an
    # operator gets for a boot that never came up.
    rows = [
      {"echo '#{@pending_json}'", :socket_pending},
      {"echo boom >&2; exit 3", {:grant_vsock, {3, "boom"}}}
    ]

    for {script, expected_reason} <- rows do
      vm_id = Hyper.Vm.Id.generate()
      stub_helper!(tmp, script)

      result = Configuring.handle(:state_timeout, :grant_vsock, data(vm_id, -1))

      assert {:stop, {:shutdown, {:boot_failed, {:vsock_grant_timeout, reason}}}, _} = result
      assert reason == expected_reason
    end
  end

  # gen_statem data for a VM `offset_ms` away from its boot deadline. Only the
  # fields the Configuring grant path reads are populated.
  defp data(vm_id, offset_ms) do
    %State{
      opts: %Opts{vm_id: vm_id},
      boot_deadline: System.monotonic_time(:millisecond) + offset_ms
    }
  end

  # Point Hyper.Cfg.Tools.suidhelper/0 (runtime source) at a stub script and
  # restore the previous binding afterwards.
  defp stub_helper!(tmp, body) do
    script = Path.join(tmp, "suidhelper-stub-#{System.unique_integer([:positive])}")
    File.write!(script, "#!/bin/sh\n#{body}\n")
    File.chmod!(script, 0o755)

    previous = Application.get_env(:hyper, Hyper.Cfg.Tools, [])
    Application.put_env(:hyper, Hyper.Cfg.Tools, Keyword.put(previous, :suidhelper, script))
    on_exit(fn -> Application.put_env(:hyper, Hyper.Cfg.Tools, previous) end)
  end

  # Horde materialises registrations asynchronously; wait until the stub is
  # resolvable through the routing key before driving the handler at it.
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
