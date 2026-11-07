defmodule Hyper.Node.FireVMM.DaemonTest do
  @moduledoc """
  `Daemon` shells every privileged step (netns prepare/teardown, chroot
  removal, jailer launch) through the setuid helper binary named by
  `Hyper.Cfg.Tools.suidhelper/0`. These tests point that at a small fake
  script instead of the real setuid helper — the same seam `JailerTest` uses
  for `tools.firecracker`/`tools.jailer` — so they can observe real call
  order and gating without root, a real netns, or a real firecracker process.

  Invariants under test (networking is mandatory — these fire unconditionally,
  even with no `[network]` table in config):

    * the jailer enters the netns via `--netns` (Task 8), so it must already
      exist: `network prepare` must run before the `jailer` launch.
    * jail clearing (`chroot-jail remove`) and network teardown both fire
      wherever the jail is cleared (stale-reset on relaunch, and terminate).
  """

  use ExUnit.Case, async: false

  alias Hyper.Node.FireVMM
  alias Hyper.Node.FireVMM.Daemon

  @vm_id "vdaemontest01"

  setup do
    log = Path.join(System.tmp_dir!(), "daemon_test_#{System.unique_integer([:positive])}.log")
    fake = write_fake_suidhelper!(log)

    on_exit(fn ->
      Hyper.Cfg.Toml.reload()
      File.rm(fake)
      File.rm(log)
    end)

    {:ok, log: log, fake: fake}
  end

  @rootfs "/dev/mapper/hyper-vdaemontest01"

  defp opts(mutable \\ nil) do
    %FireVMM.Opts{
      vm_id: @vm_id,
      uid: 900_500,
      gid: 900_500,
      type: :micro,
      arch: :x86_64,
      mutable: mutable,
      kernel: "/nonexistent/vmlinux",
      boot_args: nil
    }
  end

  # A stand-in for hyper-suidhelper: appends "<argv...>" as one line per
  # invocation (so call order is observable across the test) and prints an
  # empty JSON object so `SuidHelper.exec/1`'s `Jason.decode!/1` succeeds.
  # Exits immediately, so a `jailer` invocation looks like an instant crash
  # rather than a live firecracker — fine here, only the call log matters.
  defp write_fake_suidhelper!(log) do
    path =
      Path.join(System.tmp_dir!(), "fake_suidhelper_#{System.unique_integer([:positive])}.sh")

    File.write!(path, """
    #!/usr/bin/env bash
    printf '%s\n' "$1" >> #{log}
    echo '{}'
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp mutable_stub(device) do
    spawn_link(fn ->
      receive do
        {:"$gen_call", from, :blk_path} -> GenServer.reply(from, device)
      end
    end)
  end

  defp requests(log) do
    log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  defp calls(log) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> Jason.decode!() |> Map.fetch!("op")))
  end

  # `Jailer.chroot_dir/1` derives the in-jail exec name from `tools.firecracker`
  # (see `JailerTest`), so every scenario stubs it alongside `tools.suidhelper`
  # to keep it off the real filesystem.
  defp put_toml(fake) do
    tools = %{"suidhelper" => fake, "firecracker" => "/usr/local/bin/firecracker"}
    Hyper.Cfg.Toml.put_cache(%{"tools" => tools})
  end

  describe "netns lifecycle (mandatory)" do
    test "start_link boots with one vm_launch carrying the kernel and the volume's device",
         %{log: log, fake: fake} do
      put_toml(fake)

      Process.flag(:trap_exit, true)
      {:ok, pid} = Daemon.start_link(opts(mutable_stub(@rootfs)))
      assert_receive {:EXIT, ^pid, _reason}, 2_000

      assert [
               %{"op" => "vm_launch", "kernel" => "/nonexistent/vmlinux", "device" => @rootfs}
               | exit
             ] = requests(log)

      assert Enum.map(exit, & &1["op"]) == ["vm_teardown"]
    end

    test "terminate/2 tears down the jail and its network", %{log: log, fake: fake} do
      put_toml(fake)

      assert :ok =
               Daemon.terminate(:shutdown, %Daemon{
                 opts: opts(),
                 muontrap: nil
               })

      assert calls(log) == ["vm_teardown"]
    end
  end
end
