defmodule Hyper.Node.FireVMM.Net do
  @moduledoc """
  Unimplemented placeholder pending the VM-networking rewrite.

  VMs currently boot with no NIC and no `ip=` / `hyper.resolver=` kernel
  cmdline fragments. Every function raises; nothing in Hyper calls them.
  """

  @doc "Unimplemented: the guest kernel `ip=` autoconfig fragment."
  @spec ip_cmdline() :: no_return()
  def ip_cmdline,
    do:
      raise(
        "Hyper.Node.FireVMM.Net.ip_cmdline/0 is unimplemented: VM networking is being rewritten"
      )

  @doc "Unimplemented: the guest kernel `hyper.resolver=` fragment."
  @spec resolver_cmdline(String.t()) :: no_return()
  def resolver_cmdline(_resolver),
    do:
      raise(
        "Hyper.Node.FireVMM.Net.resolver_cmdline/1 is unimplemented: VM networking is being rewritten"
      )

  @doc "Unimplemented: the guest MAC for `vm_id`."
  @spec guest_mac(Hyper.Vm.Id.t()) :: no_return()
  def guest_mac(_vm_id),
    do:
      raise(
        "Hyper.Node.FireVMM.Net.guest_mac/1 is unimplemented: VM networking is being rewritten"
      )

  @doc "Unimplemented: the Firecracker NIC spec for `vm_id`."
  @spec interface(Hyper.Vm.Id.t()) :: no_return()
  def interface(_vm_id),
    do:
      raise(
        "Hyper.Node.FireVMM.Net.interface/1 is unimplemented: VM networking is being rewritten"
      )
end
