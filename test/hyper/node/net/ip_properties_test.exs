defmodule Hyper.Node.Net.IpPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Node.Net.Ip
  alias Hyper.Node.Net.Ip.Host

  property "a NetId's uplink address is the second host of the NetId-th /30 of the transit prefix" do
    check all({host, net_id} <- host_and_net_id()) do
      {transit, len} = host.transit_prefix
      ipv4 = ipv4_int(Ip.lease(host, net_id).ipv4)

      assert ipv4 >>> (32 - len) == ipv4_int(transit) >>> (32 - len)
      assert (ipv4 >>> 2) - (ipv4_int(transit) >>> 2) == net_id
      assert (ipv4 &&& 0b11) == 2
    end
  end

  property "a NetId's guest IPv6 sits in the VM prefix with the NetId as its low bits" do
    check all({host, net_id} <- host_and_net_id()) do
      {vm, len} = host.vm_prefix
      ipv6 = ipv6_int(Ip.lease(host, net_id).ipv6)

      assert ipv6 >>> (128 - len) == ipv6_int(vm) >>> (128 - len)
      assert (ipv6 &&& (1 <<< (128 - len)) - 1) == net_id
    end
  end

  property "the guest is told the IPv6 address the VM is reported reachable at" do
    check all({host, net_id} <- host_and_net_id()) do
      lease = Ip.lease(host, net_id)
      ["hyper.ip6=" <> told] = lease |> Ip.guest_args() |> Enum.filter(&(&1 =~ "hyper.ip6="))

      assert {:ok, ipv6} = :inet.parse_ipv6strict_address(String.to_charlist(told))
      assert Ip.addresses(lease) == [ipv6]
    end
  end

  property "there is one NetId per /30 of the transit prefix" do
    check all(host <- host()) do
      {_, len} = host.transit_prefix

      assert Enum.count(Ip.net_ids(host)) == 1 <<< (30 - len)
      assert Enum.min(Ip.net_ids(host)) == 0
    end
  end

  defp host do
    gen all(
          len <- integer(8..30),
          transit <- integer(0..0xFFFFFFFF),
          vm <- integer(0..((1 <<< 80) - 1))
        ) do
      %Host{
        uplink: "if0",
        transit_prefix: {ipv4((transit >>> (32 - len)) <<< (32 - len)), len},
        vm_prefix: {ipv6(vm <<< 48), 80}
      }
    end
  end

  defp host_and_net_id do
    bind(host(), fn host ->
      first..last//1 = Ip.net_ids(host)
      tuple({constant(host), integer(first..last)})
    end)
  end

  defp ipv4_int({a, b, c, d}) do
    <<n::32>> = <<a, b, c, d>>
    n
  end

  defp ipv4(n) do
    <<a, b, c, d>> = <<n::32>>
    {a, b, c, d}
  end

  defp ipv6_int(words) do
    words |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< 16 ||| &1))
  end

  defp ipv6(n) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = <<n::128>>
    {a, b, c, d, e, f, g, h}
  end
end
