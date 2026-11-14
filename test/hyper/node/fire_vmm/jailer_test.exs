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
      net_id: 64,
      firewall: %Hyper.Vm.Firewall{inbound: [], outbound_blocked: [{:tcp, 25..25}]},
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
             "net_id" => 64,
             "kernel" => "/srv/hyper/redist/vmlinux/vmlinux-x86_64-6.1",
             "device" => @rootfs,
             "firewall" => %{
               "inbound" => [],
               "outbound_blocked" => [%{"protocol" => "tcp", "ports" => [25, 25]}]
             }
           } = request()
  end

  test "the request carries the :micro cgroup limits and nothing the helper owns" do
    cgroup = Hyper.Vm.Instance.Spec.cgroup_v2(Hyper.Vm.Instance.spec(:micro))

    assert Map.keys(request()) |> Enum.sort() ==
             ~w(device firewall gid id kernel limits net_id op uid)

    assert request()["limits"]["memory_max"] == cgroup.memory_max

    assert request()["limits"]["cpu_max"] == %{
             "quota_us" => cgroup.cpu_max.quota_us,
             "period_us" => cgroup.cpu_max.period_us
           }
  end

  test "the BEAM dials the helper-pinned sockets, never a path inside the jail" do
    assert {Jailer.host_socket(@vm_id), Jailer.host_vsock(@vm_id)} ==
             {"/srv/hyper/socks/fc-#{@vm_id}-api.socket",
              "/srv/hyper/socks/fc-#{@vm_id}-vsock.sock"}
  end
end
