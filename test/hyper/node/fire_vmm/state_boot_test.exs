defmodule Hyper.Node.FireVMM.StateBootTest do
  use ExUnit.Case, async: true

  # Exercises the boot protocol states directly as gen_statem callbacks, with an
  # injected recording `run` on the State data - no supervision tree needed. The
  # `booting` happy path (which calls ensure_daemon -> the tree) is covered by
  # these state tests plus StateInitTest, not unit-tested here.

  alias Hyper.Firecracker.Api.{InstanceInfo, SnapshotLoadParams}
  alias Hyper.Node.FireVMM.{BootSpec, State}
  alias Hyper.Test.FirecrackerRecordingClient, as: Rec

  @cold {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}

  defp run_with(respond) do
    me = self()
    fn op_fun -> op_fun.(client: Rec, recorder: me, respond: respond) end
  end

  defp collect_calls do
    receive do
      {:fc_call, m, u, b} -> [{m, u, b} | collect_calls()]
    after
      0 -> []
    end
  end

  defp urls, do: collect_calls() |> Enum.map(fn {_m, u, _b} -> u end)

  defp data(opts) do
    source = Keyword.get(opts, :source, @cold)
    # booting/3 re-resolves from source; spec is nil for sources that can't resolve.
    spec =
      case BootSpec.resolve(source, :centi) do
        {:ok, s} -> s
        {:error, _} -> nil
      end

    %State{
      id: 1,
      socket_path: "/tmp/x.socket",
      source: source,
      type: :centi,
      binary: "jailer",
      args: [],
      run: run_with(Keyword.fetch!(opts, :respond)),
      spec: spec,
      boot_deadline:
        Keyword.get(opts, :boot_deadline, System.monotonic_time(:millisecond) + 10_000)
    }
  end

  describe "booting/3" do
    test "an unresolvable source stops without launching a daemon" do
      d = data(source: {:vm, "vm-1"}, respond: fn _ -> :ok end)

      assert {:stop, {:shutdown, {:boot_failed, {:unsupported_source, :vm}}}, _} =
               State.booting(:state_timeout, :launch, d)
    end
  end

  describe "awaiting_api/3" do
    test "a not-started daemon transitions to :configuring" do
      d = data(respond: fn %{url: "/"} -> {:ok, %InstanceInfo{state: "Not started"}} end)

      assert {:next_state, :configuring, ^d, [{:state_timeout, 0, :configure}]} =
               State.awaiting_api(:state_timeout, :probe, d)

      # Only the readiness probe was issued.
      assert [{:get, "/", _}] = collect_calls()
    end

    test "an already-running adopted guest skips config and goes straight to :running" do
      d = data(respond: fn %{url: "/"} -> {:ok, %InstanceInfo{state: "Running"}} end)

      assert {:next_state, :running, ^d} = State.awaiting_api(:state_timeout, :probe, d)
      assert ["/"] = urls()
    end

    test "a transport error before the deadline re-arms the probe" do
      d = data(respond: fn _ -> {:error, {:transport, :enoent}} end)

      assert {:keep_state_and_data, [{:state_timeout, _, :probe}]} =
               State.awaiting_api(:state_timeout, :probe, d)
    end

    test "a transport error past the deadline stops as :daemon_unready" do
      d =
        data(
          respond: fn _ -> {:error, {:transport, :enoent}} end,
          boot_deadline: System.monotonic_time(:millisecond) - 1
        )

      assert {:stop, {:shutdown, {:boot_failed, :daemon_unready}}, ^d} =
               State.awaiting_api(:state_timeout, :probe, d)
    end

    test "daemon death transitions to :crashed" do
      ref = make_ref()
      d = %{data(respond: fn _ -> :ok end) | daemon_ref: ref}

      assert {:next_state, :crashed, %State{daemon: nil, daemon_ref: nil},
              [{:state_timeout, _, :recover}]} =
               State.awaiting_api(:info, {:DOWN, ref, :process, self(), :killed}, d)
    end
  end

  describe "configuring/3" do
    test "cold boot issues the config sequence in order, then :running" do
      d = data(respond: fn _ -> :ok end)

      assert {:next_state, :running, ^d} = State.configuring(:state_timeout, :configure, d)
      assert urls() == ["/machine-config", "/boot-source", "/drives/rootfs", "/actions"]
    end

    test "restore issues load_snapshot (resume) then :running" do
      d = data(source: {:snapshot, "/snaps/v1"}, respond: fn _ -> :ok end)

      assert {:next_state, :running, ^d} = State.configuring(:state_timeout, :configure, d)
      assert [{:put, "/snapshot/load", %SnapshotLoadParams{resume_vm: true}}] = collect_calls()
    end

    test "a failing step aborts the sequence and stops the VM" do
      respond = fn
        %{url: "/machine-config"} -> {:error, {:api, 400, "bad"}}
        _ -> :ok
      end

      d = data(respond: respond)

      assert {:stop, {:shutdown, {:boot_failed, {:api, 400, "bad"}}}, ^d} =
               State.configuring(:state_timeout, :configure, d)

      # Nothing issued after the failing machine-config.
      assert ["/machine-config"] = urls()
    end

    test "daemon death transitions to :crashed" do
      ref = make_ref()
      d = %{data(respond: fn _ -> :ok end) | daemon_ref: ref}

      assert {:next_state, :crashed, %State{daemon: nil, daemon_ref: nil},
              [{:state_timeout, _, :recover}]} =
               State.configuring(:info, {:DOWN, ref, :process, self(), :killed}, d)
    end
  end

  describe "pause/resume rejected during boot" do
    test "awaiting_api rejects a pause call" do
      d = data(respond: fn _ -> :ok end)
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_running}}]} =
               State.awaiting_api({:call, from}, :pause, d)
    end

    test "configuring rejects a resume call" do
      d = data(respond: fn _ -> :ok end)
      from = {self(), make_ref()}

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :not_running}}]} =
               State.configuring({:call, from}, :resume, d)
    end
  end

  describe "stop during boot" do
    test "awaiting_api accepts a stop call and moves to :stopping" do
      d = data(respond: fn _ -> :ok end)
      from = {self(), make_ref()}

      assert {:next_state, :stopping, ^d, [{:reply, ^from, :ok}]} =
               State.awaiting_api({:call, from}, :stop, d)
    end
  end
end
