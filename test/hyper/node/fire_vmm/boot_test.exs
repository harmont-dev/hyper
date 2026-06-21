defmodule Hyper.Node.FireVMM.BootTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Boot
  alias Hyper.Test.FirecrackerRecordingClient, as: Rec

  # Build a `run` closure that drives the recording client. `respond` is a
  # 1-arity fun `info -> result`; it defaults to always `:ok`.
  defp run_with(respond \\ fn _ -> :ok end) do
    me = self()
    fn op_fun -> op_fun.(client: Rec, recorder: me, respond: respond) end
  end

  # Collect every {:fc_call, ...} the recording client sent, in order.
  defp collect_calls do
    receive do
      {:fc_call, method, url, body} -> [{method, url, body} | collect_calls()]
    after
      0 -> []
    end
  end

  # describe_instance must report ready; everything else 204/:ok.
  defp ready(_info), do: :ok

  defp ready_or_info(%{url: "/"}),
    do: {:ok, %Hyper.Firecracker.Api.InstanceInfo{state: "Not started"}}

  defp ready_or_info(_info), do: :ok

  describe "boot/4 cold" do
    test "issues machine-config, boot-source, root drive, then InstanceStart in order" do
      src = {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}

      assert :ok =
               Boot.boot(run_with(&ready_or_info/1), src, :centi, ready_interval_ms: 0)

      calls = collect_calls()
      urls = Enum.map(calls, fn {_m, u, _b} -> u end)

      assert urls == ["/", "/machine-config", "/boot-source", "/drives/rootfs", "/actions"]

      # The InstanceStart action body carries the right action_type.
      {:put, "/actions", action} = List.last(calls)
      assert %Hyper.Firecracker.Api.InstanceActionInfo{action_type: "InstanceStart"} = action
    end

    test "stops the sequence and returns the error if a step fails" do
      src = {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}

      respond = fn
        %{url: "/"} -> {:ok, %Hyper.Firecracker.Api.InstanceInfo{state: "Not started"}}
        %{url: "/machine-config"} -> {:error, {:api, 400, "bad vcpu"}}
        _ -> :ok
      end

      assert {:error, {:api, 400, "bad vcpu"}} =
               Boot.boot(run_with(respond), src, :centi, ready_interval_ms: 0)

      urls = collect_calls() |> Enum.map(fn {_m, u, _b} -> u end)
      # Readiness + machine-config attempted; nothing after the failure.
      assert urls == ["/", "/machine-config"]
    end
  end

  describe "boot/4 restore" do
    test "loads the snapshot with resume_vm and starts nothing else" do
      assert :ok =
               Boot.boot(run_with(&ready_or_info/1), {:snapshot, "/snaps/v1"}, :centi,
                 ready_interval_ms: 0
               )

      calls = collect_calls()
      urls = Enum.map(calls, fn {_m, u, _b} -> u end)
      assert urls == ["/", "/snapshot/load"]

      {:put, "/snapshot/load", params} = List.last(calls)
      assert %Hyper.Firecracker.Api.SnapshotLoadParams{resume_vm: true} = params
    end
  end

  describe "boot/4 readiness" do
    test "retries describe_instance until the daemon answers" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      respond = fn
        %{url: "/"} ->
          n = Agent.get_and_update(counter, fn n -> {n, n + 1} end)
          if n < 2, do: {:error, {:transport, :enoent}}, else: {:ok, %Hyper.Firecracker.Api.InstanceInfo{state: "Not started"}}

        _ ->
          :ok
      end

      src = {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}
      assert :ok = Boot.boot(run_with(respond), src, :centi, ready_interval_ms: 0)
    end

    test "gives up after the deadline" do
      respond = fn _ -> {:error, {:transport, :enoent}} end
      src = {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}

      assert {:error, :daemon_unready} =
               Boot.boot(run_with(respond), src, :centi,
                 ready_interval_ms: 0,
                 ready_timeout_ms: 0
               )
    end
  end

  describe "boot/4 re-adoption" do
    test "skips configuration when the adopted daemon already runs a guest" do
      respond = fn
        %{url: "/"} -> {:ok, %Hyper.Firecracker.Api.InstanceInfo{state: "Running"}}
        _ -> :ok
      end

      src = {:cold, %{kernel_image_path: "/vmlinux", root_drive_path: "/rootfs.ext4"}}
      assert :ok = Boot.boot(run_with(respond), src, :centi, ready_interval_ms: 0)

      # Only the readiness/state probe was issued; no config PUTs, no InstanceStart.
      urls = collect_calls() |> Enum.map(fn {_m, u, _b} -> u end)
      assert urls == ["/"]
    end

    test "also skips for an already-paused adopted guest" do
      respond = fn
        %{url: "/"} -> {:ok, %Hyper.Firecracker.Api.InstanceInfo{state: "Paused"}}
        _ -> :ok
      end

      src = {:snapshot, "/snaps/v1"}
      assert :ok = Boot.boot(run_with(respond), src, :centi, ready_interval_ms: 0)
      assert ["/"] = collect_calls() |> Enum.map(fn {_m, u, _b} -> u end)
    end
  end

  describe "pause/1 and resume/1" do
    test "PATCH /vm with the right state" do
      assert :ok = Boot.pause(run_with(&ready/1))
      assert [{:patch, "/vm", %Hyper.Firecracker.Api.Vm{state: "Paused"}}] = collect_calls()

      assert :ok = Boot.resume(run_with(&ready/1))
      assert [{:patch, "/vm", %Hyper.Firecracker.Api.Vm{state: "Resumed"}}] = collect_calls()
    end
  end
end
