defmodule Hyper.Node.FireVMM.NetTest do
  use ExUnit.Case, async: true
  alias Hyper.Node.FireVMM.Net

  test "guest_mac is a stable locally-administered unicast MAC" do
    mac = Net.guest_mac("vabcdef")
    assert mac == Net.guest_mac("vabcdef"), "must be deterministic in vm_id"

    octets = String.split(mac, ":")
    # Firecracker rejects anything but a full six-octet MAC — a short address
    # 400s the NIC config and the VM never boots.
    assert length(octets) == 6, "MAC must have six octets, got #{mac}"
    assert Enum.all?(octets, &(byte_size(&1) == 2 and match?({_, ""}, Integer.parse(&1, 16))))

    <<byte>> = Base.decode16!(hd(octets), case: :mixed)
    # locally administered (bit 1 set), unicast (bit 0 clear)
    assert Bitwise.band(byte, 0x02) == 0x02
    assert Bitwise.band(byte, 0x01) == 0x00
  end

  test "distinct vm_ids get distinct MACs" do
    refute Net.guest_mac("vaaa") == Net.guest_mac("vbbb")
  end

  test "ip_cmdline pins the inner-world contract" do
    assert Net.ip_cmdline() == "ip=172.30.0.2::172.30.0.1:255.255.255.252::eth0:off"
  end

  test "resolver_cmdline formats the hyper.resolver= fragment for the given resolver" do
    assert Net.resolver_cmdline("1.1.1.1") == "hyper.resolver=1.1.1.1"
    assert Net.resolver_cmdline("10.0.0.53") == "hyper.resolver=10.0.0.53"
  end

  test "interface targets tap0/eth0 with the derived MAC" do
    nic = Net.interface("vabcdef")
    assert nic.iface_id == "eth0"
    assert nic.host_dev_name == "tap0"
    assert nic.guest_mac == Net.guest_mac("vabcdef")
  end
end
