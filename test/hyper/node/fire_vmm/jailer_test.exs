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

  # Stub the cached TOML so firecracker/jailer resolve to dummy paths without
  # requiring /etc/hyper/config.toml on the test host. async: false because the
  # cache is global state.
  @rootfs "/dev/mapper/hyper-vjailertest"

  setup do
    Hyper.Cfg.Toml.put_cache(%{
      "tools" => %{
        "firecracker" => "/usr/local/bin/firecracker",
        "jailer" => "/usr/local/bin/jailer"
      }
    })

    on_exit(fn -> Hyper.Cfg.Toml.reload() end)
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
    assert Jailer.command(micro_opts(), @rootfs).binary == Hyper.Cfg.Tools.suidhelper()
  end

  defp request do
    %{args: [json]} = Jailer.command(micro_opts(), @rootfs)
    Jason.decode!(json)
  end

  test "args are a single vm_launch request carrying the ids and boot artifacts" do
    assert %{
             "op" => "vm_launch",
             "id" => @vm_id,
             "uid" => 900_001,
             "gid" => 900_001,
             "kernel" => "/srv/hyper/redist/vmlinux/vmlinux-x86_64-6.1",
             "device" => @rootfs
           } = request()
  end

  test "the request carries the :micro cgroup limits and nothing the helper owns" do
    cgroup = Hyper.Vm.Instance.Spec.cgroup_v2(Hyper.Vm.Instance.spec(:micro))

    assert Map.keys(request()) |> Enum.sort() ==
             ~w(device gid id kernel limits op uid)

    assert request()["limits"]["memory_max"] == cgroup.memory_max

    assert request()["limits"]["cpu_max"] == %{
             "quota_us" => cgroup.cpu_max.quota_us,
             "period_us" => cgroup.cpu_max.period_us
           }
  end

  test "host_vsock/1 returns the chroot-rooted host path for vsock.sock" do
    assert Jailer.host_vsock(@vm_id) ==
             "/srv/hyper/jails/firecracker/#{@vm_id}/root/vsock.sock"
  end

  describe "Checks.network_ready/0" do
    test "refuses to start when no [network] table is configured" do
      # Networking is mandatory: absence is a hard startup failure, not a
      # silent opt-out.
      Hyper.Cfg.Toml.put_cache(%{})
      on_exit(fn -> Hyper.Cfg.Toml.reload() end)

      assert Jailer.Checks.network_ready() == {:error, :network_not_configured}
    end

    test "fails when uplink iface is absent" do
      Hyper.Cfg.Toml.put_cache(%{"network" => %{"uplink" => "hyper-nonexistent-nic"}})
      on_exit(fn -> Hyper.Cfg.Toml.reload() end)

      assert {:error, {:missing_uplink, "hyper-nonexistent-nic"}} = Jailer.Checks.network_ready()
    end
  end
end
