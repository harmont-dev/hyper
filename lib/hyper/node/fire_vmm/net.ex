defmodule Hyper.Node.FireVMM.Net do
  @moduledoc "Firecracker network configuration for a particular VM."

  alias Hyper.Node.Net.Lease

  @doc "MAC for `vm_id`."
  @spec guest_mac(Hyper.Vm.Id.t()) :: no_return()
  def guest_mac(_vm_id),
    do:
      raise(
        "Hyper.Node.FireVMM.Net.guest_mac/1 is unimplemented: VM networking is being rewritten"
      )

  @doc "The Firecracker NIC spec (guest `eth0` bound to in-netns `tap0`)."
  @spec interface(Lease.t()) :: no_return()
  def interface(_lease),
    do:
      raise(
        "Hyper.Node.FireVMM.Net.interface/1 is unimplemented: VM networking is being rewritten"
      )

  @doc "Kernel cmdline fragments."
  @spec cmdline(Lease.t(), [:inet.ip_address()]) :: no_return()
  def cmdline(_lease, _resolvers),
    do:
      raise("Hyper.Node.FireVMM.Net.cmdline/2 is unimplemented: VM networking is being rewritten")
end
