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

  defp opts do
    %FireVMM.Opts{
      vm_id: @vm_id,
      uid: 900_500,
      gid: 900_500,
      type: :micro,
      arch: :x86_64,
      mutable: nil,
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
    echo "$*" >> #{log}
    echo '{}'
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp calls(log) do
    log
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&hd(String.split(&1, " ")))
  end

  # `Jailer.chroot_dir/1` derives the in-jail exec name from `tools.firecracker`
  # (see `JailerTest`), so every scenario stubs it alongside `tools.suidhelper`
  # to keep it off the real filesystem.
  defp put_toml(fake) do
    tools = %{"suidhelper" => fake, "firecracker" => "/usr/local/bin/firecracker"}
    Hyper.Cfg.Toml.put_cache(%{"tools" => tools})
  end

  describe "netns lifecycle (mandatory)" do
    test "start_link prepares the netns before launching the jailer", %{log: log, fake: fake} do
      # No [network] table on purpose: the netns prepare must fire regardless,
      # since networking is mandatory rather than config-gated.
      put_toml(fake)

      Process.flag(:trap_exit, true)
      {:ok, pid} = Daemon.start_link(opts())
      assert_receive {:EXIT, ^pid, _reason}, 2_000

      ops = calls(log)
      prepare_at = Enum.find_index(ops, &(&1 == "network"))
      jailer_at = Enum.find_index(ops, &(&1 == "jailer"))

      assert prepare_at, "expected a `network` (prepare) call before the jailer launch"
      assert jailer_at, "expected the jailer to have been launched"
      assert prepare_at < jailer_at, "netns must be prepared before the jailer enters it"
    end

    test "terminate/2 tears down both the network and the chroot jail", %{log: log, fake: fake} do
      put_toml(fake)

      assert :ok =
               Daemon.terminate(:shutdown, %Daemon{
                 opts: opts(),
                 muontrap: nil
               })

      ops = calls(log)
      assert "network" in ops
      assert "chroot-jail" in ops
    end
  end
end
