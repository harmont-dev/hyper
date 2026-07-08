defmodule Hyper.Node.FireVMM.Net do
  @moduledoc """
  The per-VM *inner-world* networking contract. Every VM's netns is identical —
  `tap0` at 172.30.0.1/30, guest at 172.30.0.2/30 — so a snapshot clone restores
  a correct network with zero renumbering; host-side uniqueness is the helper's
  job (see `Hyper.SuidHelper.Network`). This module owns the three values that
  must agree between the guest kernel cmdline, the Firecracker NIC config, and
  the helper: the guest MAC, the `ip=` autoconfig string, and the NIC spec.
  """
  alias Hyper.Firecracker.Api.NetworkInterface

  @guest_ip "172.30.0.2"
  @tap_ip "172.30.0.1"
  @netmask "255.255.255.252"
  @iface "eth0"
  @tap "tap0"

  @doc "Kernel `ip=` autoconfig fragment appended to every networked VM's cmdline."
  @spec ip_cmdline() :: String.t()
  def ip_cmdline, do: "ip=#{@guest_ip}::#{@tap_ip}:#{@netmask}::#{@iface}:off"

  @doc """
  Kernel `hyper.resolver=` cmdline fragment carrying the DNS resolver IP the
  PID-1 guest agent writes to `/etc/resolv.conf` — kernel `ip=` autoconfig sets
  the guest's address/route but never DNS, so this closes that gap. Pure:
  callers (`BootSpec.resolve/2`) read the configured resolver themselves.
  """
  @spec resolver_cmdline(String.t()) :: String.t()
  def resolver_cmdline(resolver), do: "hyper.resolver=#{resolver}"

  @doc """
  Stable locally-administered unicast MAC for `vm_id`. Derived from a SHA-256 of
  the id so it is deterministic on any node (aids debugging); duplicate MACs are
  harmless since no two guests ever share an L2 segment (each is alone in its netns).
  """
  @spec guest_mac(Hyper.Vm.Id.t()) :: String.t()
  def guest_mac(vm_id) do
    # Six octets: the fixed locally-administered-unicast leading byte plus five
    # from the id hash. Firecracker rejects anything but a full XX:XX:XX:XX:XX:XX
    # MAC (a five-octet address 400s the NIC config and the VM never boots).
    <<_::8, b1, b2, b3, b4, b5, _::binary>> = :crypto.hash(:sha256, vm_id)

    [0x02, b1, b2, b3, b4, b5]
    |> Enum.map_join(":", &(&1 |> Integer.to_string(16) |> String.pad_leading(2, "0")))
    |> String.downcase()
  end

  @doc "The Firecracker NIC spec for `vm_id` (guest `eth0` bound to in-netns `tap0`)."
  @spec interface(Hyper.Vm.Id.t()) :: NetworkInterface.t()
  def interface(vm_id) do
    %NetworkInterface{iface_id: @iface, host_dev_name: @tap, guest_mac: guest_mac(vm_id)}
  end

  @doc false
  @spec guest_iface() :: String.t()
  def guest_iface, do: @iface
end
