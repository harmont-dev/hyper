defmodule Hyper.SuidHelper.HostInitTest do
  use ExUnit.Case, async: false

  alias Hyper.Node.Net.Ip.Host
  alias Hyper.SuidHelper
  alias Hyper.Test.SuidHelperStub

  setup do
    tmp = Path.join(System.tmp_dir!(), "host-init-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)

    if reaper = Process.whereis(Hyper.Node.Reaper) do
      :ok = :sys.suspend(reaper)
      on_exit(fn -> :sys.resume(reaper) end)
    end

    %{tmp: tmp}
  end

  test "host_ready decodes into the base and the host's network facts", %{tmp: tmp} do
    reply(
      tmp,
      ~s({"result":"host_ready","hyper_base":"/srv/hyper","net":{"uplink":"if0","transit_prefix":"10.200.0.0/16","vm_prefix":"2001:db8:0:0:1::/80"}})
    )

    assert SuidHelper.host_init() ==
             {:ok, "/srv/hyper",
              %Host{
                uplink: "if0",
                transit_prefix: {{10, 200, 0, 0}, 16},
                vm_prefix: {{0x2001, 0xDB8, 0, 0, 1, 0, 0, 0}, 80}
              }}
  end

  test "a host_ready whose network facts do not parse is refused", %{tmp: tmp} do
    rows = [
      ~s({"uplink":"if0","transit_prefix":"10.200.0.0","vm_prefix":"2001:db8:0:0:1::/80"}),
      ~s({"uplink":"if0","transit_prefix":"2001:db8::/16","vm_prefix":"2001:db8:0:0:1::/80"}),
      ~s({"uplink":"if0","transit_prefix":"10.200.0.0/16","vm_prefix":"10.0.0.0/80"}),
      ~s({"uplink":"if0","transit_prefix":"10.200.0.0/sixteen","vm_prefix":"2001:db8::/80"}),
      ~s({"transit_prefix":"10.200.0.0/16","vm_prefix":"2001:db8:0:0:1::/80"})
    ]

    for net <- rows do
      reply(tmp, ~s({"result":"host_ready","hyper_base":"/srv/hyper","net":#{net}}))

      assert {:error, {:malformed_host_net, _}} = SuidHelper.host_init(), net
    end
  end

  defp reply(tmp, json), do: SuidHelperStub.install!(tmp, "echo '#{json}'")
end
