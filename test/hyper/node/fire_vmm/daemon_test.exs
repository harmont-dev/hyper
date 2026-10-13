defmodule Hyper.Node.FireVMM.DaemonTest do
  @moduledoc """
  `Daemon` shells every privileged step (chroot removal, jailer launch)
  through the setuid helper binary named by `Hyper.Cfg.Tools.suidhelper/0`.
  These tests point that at a small fake script instead of the real setuid
  helper — the same seam `JailerTest` uses for `tools.firecracker`/`tools.jailer`
  — so they can observe the real calls without root or a real firecracker
  process.

  Invariants under test:

    * the jailer is launched, and no `network` subcommand is ever invoked
      (VM networking is unimplemented pending its rewrite).
    * `terminate/2` clears the chroot jail.
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

  describe "jail lifecycle" do
    test "start_link launches the jailer without any network setup", %{log: log, fake: fake} do
      put_toml(fake)

      Process.flag(:trap_exit, true)
      {:ok, pid} = Daemon.start_link(opts())
      assert_receive {:EXIT, ^pid, _reason}, 2_000

      ops = calls(log)
      assert "jailer" in ops
      refute "network" in ops
    end

    test "terminate/2 removes the chroot jail without any network teardown", %{
      log: log,
      fake: fake
    } do
      put_toml(fake)

      assert :ok =
               Daemon.terminate(:shutdown, %Daemon{
                 opts: opts(),
                 muontrap: nil
               })

      ops = calls(log)
      assert "chroot-jail" in ops
      refute "network" in ops
    end
  end
end
