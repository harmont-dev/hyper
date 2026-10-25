defmodule Hyper.Node.FireVMM.Net do
  @moduledoc "Firecracker network configuration for a particular VM."

  alias Hyper.Firecracker.Api.NetworkInterface
  alias Hyper.Node.Net.Lease

  @doc "MAC for `vm_id`."
  @spec guest_mac(Hyper.Vm.Id.t()) :: String.t()
  def guest_mac(_vm_id),
    do:
      raise(
        "Hyper.Node.FireVMM.Net.guest_mac/1 is unimplemented: VM networking is being rewritten"
      )

  @doc "The Firecracker NIC spec (guest `eth0` bound to in-netns `tap0`)."
  @spec interface(Lease.t()) :: NetworkInterface.t()
  def interface(_lease),
    do:
      raise(
        "Hyper.Node.FireVMM.Net.interface/1 is unimplemented: VM networking is being rewritten"
      )

  @doc "Kernel cmdline fragments."
  @spec cmdline(Lease.t(), [:inet.ip_address()]) :: String.t()
  def cmdline(_lease, _resolvers),
    do:
      raise("Hyper.Node.FireVMM.Net.cmdline/2 is unimplemented: VM networking is being rewritten")
end
