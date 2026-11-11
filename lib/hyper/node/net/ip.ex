defmodule Hyper.Node.Net.Ip do
  @moduledoc """
  The IP layer on a VM's Ethernet link (`eth0` on `tap0`), encapsulated by
  `Hyper.Node.Net`.
  """

  import Bitwise

  alias Hyper.Node.Net.Ip.Host
  alias Hyper.Node.Net.Ip.Lease

  @transit_subnet_len 30
  @transit_subnet_addrs 4
  @uplink_host 2

  @guest_ipv4 "172.16.0.2"
  @gateway_ipv4 "172.16.0.1"
  @guest_netmask "255.255.255.252"
  @guest_iface "eth0"

  @spec net_ids(Host.t()) :: Range.t()
  def net_ids(%Host{transit_prefix: {_, len}}) do
    0..((1 <<< (@transit_subnet_len - len)) - 1)//1
  end

  @spec lease(Host.t(), Hyper.Node.Net.id()) :: Lease.t()
  def lease(%Host{transit_prefix: {transit, _}, vm_prefix: {vm, _}}, net_id)
      when is_integer(net_id) and net_id >= 0 do
    %Lease{
      net_id: net_id,
      host_veth: "vm-veth-#{net_id}",
      ipv4: ipv4(ipv4_int(transit) + @transit_subnet_addrs * net_id + @uplink_host),
      ipv6: ipv6(bor(ipv6_int(vm), net_id))
    }
  end

  @spec guest_args(Lease.t()) :: [String.t()]
  def guest_args(%Lease{ipv6: ipv6}) do
    [
      "ip=#{@guest_ipv4}::#{@gateway_ipv4}:#{@guest_netmask}::#{@guest_iface}:off:#{@gateway_ipv4}",
      "hyper.ip6=#{:inet.ntoa(ipv6)}"
    ]
  end

  @spec addresses(Lease.t()) :: [:inet.ip_address()]
  def addresses(%Lease{ipv6: ipv6}), do: [ipv6]

  @spec ipv4_int(:inet.ip4_address()) :: non_neg_integer()
  defp ipv4_int({a, b, c, d}) do
    <<n::32>> = <<a, b, c, d>>
    n
  end

  @spec ipv4(non_neg_integer()) :: :inet.ip4_address()
  defp ipv4(n) do
    <<a, b, c, d>> = <<n::32>>
    {a, b, c, d}
  end

  @spec ipv6_int(:inet.ip6_address()) :: non_neg_integer()
  defp ipv6_int({a, b, c, d, e, f, g, h}) do
    <<n::128>> = <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>
    n
  end

  @spec ipv6(non_neg_integer()) :: :inet.ip6_address()
  defp ipv6(n) do
    <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>> = <<n::128>>
    {a, b, c, d, e, f, g, h}
  end
end
