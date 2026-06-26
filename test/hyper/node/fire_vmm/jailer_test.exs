defmodule Hyper.Node.FireVMM.JailerTest do
  @moduledoc """
  Examples for `Hyper.Node.FireVMM.Jailer.command/1`.

  Load-bearing invariant: the BEAM must never place a privileged binary path
  (firecracker, jailer) or lifecycle flags owned by the suidhelper (`--exec-file`,
  `--chroot-base-dir`, `--cgroup-version`, `--parent-cgroup`, `--`) in the args
  it hands to the helper. The helper derives those from its trusted config.
  """

  use ExUnit.Case, async: false

  alias Hyper.Node.FireVMM
  alias Hyper.Node.FireVMM.Jailer

  @vm_id "vmtest01"

  # Stub config_toml persistent_term so firecracker_bin/jailer_bin resolve
  # to dummy paths without requiring /etc/hyper/config.toml on the test host.
  # async: false because persistent_term is global state.
  setup do
    :persistent_term.put({Hyper.Config, :config_toml}, %{
      "tools" => %{
        "firecracker" => "/usr/local/bin/firecracker",
        "jailer" => "/usr/local/bin/jailer"
      }
    })

    on_exit(fn -> :persistent_term.erase({Hyper.Config, :config_toml}) end)
  end

  defp micro_opts do
    %FireVMM.Opts{
      vm_id: @vm_id,
      uid: 900_001,
      gid: 900_001,
      type: :micro,
      arch: :x86_64,
      mutable: nil,
      kernel: "/srv/hyper/redist/vmlinux/vmlinux-x86_64-6.1",
      boot_args: nil
    }
  end

  test "binary is the suid helper" do
    assert Jailer.command(micro_opts()).binary == Hyper.Config.suid_helper()
  end

  test "args start with the jailer subcommand" do
    %{args: [first | _]} = Jailer.command(micro_opts())
    assert first == "jailer"
  end

  test "args contain --id, --uid, --gid with the opts values" do
    %{args: args} = Jailer.command(micro_opts())
    assert "--id" in args
    assert @vm_id in args
    assert "--uid" in args
    assert "--gid" in args
    assert "900001" in args
  end

  test "args end with --api-sock /api.socket" do
    %{args: args} = Jailer.command(micro_opts())
    assert Enum.take(args, -2) == ["--api-sock", "/api.socket"]
  end

  test "args do not contain privileged flags owned by the suidhelper" do
    %{args: args} = Jailer.command(micro_opts())
    refute "--exec-file" in args
    refute "--chroot-base-dir" in args
    refute "--cgroup-version" in args
    refute "--parent-cgroup" in args
    refute "--" in args
  end

  test "args include --cgroup cpu.max and memory.max for :micro type" do
    %{args: args} = Jailer.command(micro_opts())
    assert "--cgroup" in args
    assert Enum.any?(args, &String.starts_with?(&1, "cpu.max="))
    assert Enum.any?(args, &String.starts_with?(&1, "memory.max="))
  end
end
