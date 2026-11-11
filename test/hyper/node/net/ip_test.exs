defmodule Hyper.Node.Net.IpTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Net.Ip
  alias Hyper.Node.Net.Ip.Host

  @host %Host{
    uplink: "if0",
    transit_prefix: {{10, 200, 0, 0}, 16},
    vm_prefix: {{0x2001, 0xDB8, 0, 0, 1, 0, 0, 0}, 80}
  }

  test "the helper's transit prefix numbers NetIds 0..16383" do
    assert Ip.net_ids(@host) == 0..16_383//1
  end

  test "a NetId leases the cookbook's addresses" do
    rows = [
      {0, "vm-veth-0", "10.200.0.2", "2001:db8::1:0:0:0"},
      {1, "vm-veth-1", "10.200.0.6", "2001:db8::1:0:0:1"},
      {64, "vm-veth-64", "10.200.1.2", "2001:db8::1:0:0:40"},
      {16_383, "vm-veth-16383", "10.200.255.254", "2001:db8::1:0:0:3fff"}
    ]

    for {net_id, veth, ipv4, ipv6} <- rows do
      lease = Ip.lease(@host, net_id)

      assert {lease.host_veth, lease.ipv4, lease.ipv6} == {veth, parse(ipv4), parse(ipv6)},
             "net_id #{net_id}"
    end
  end

  test "every guest autoconfigures the same IPv4 link behind tap0, resolving through its gateway" do
    for net_id <- [0, 16_383] do
      assert "ip=172.16.0.2::172.16.0.1:255.255.255.252::eth0:off:172.16.0.1" in Ip.guest_args(
               Ip.lease(@host, net_id)
             )
    end
  end

  defp parse(address) do
    {:ok, ip} = address |> String.to_charlist() |> :inet.parse_strict_address()
    ip
  end
end
