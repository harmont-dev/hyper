defmodule Hyper.Node.Net.Ip do
  @moduledoc """
  The IP layer on a VM's Ethernet link (`eth0` on `tap0`), encapsulated by
  `Hyper.Node.Net`.
  """

  alias Hyper.Node.Net.Ip.{Host, Lease}

  @doc "Get the IP layer's host-wide facts."
  @spec host() :: Host.t()
  def host,
    do: raise("Hyper.Node.Net.Ip.host/0 is unimplemented: VM networking is being rewritten")

  @doc "Kernel cmdline fragments configuring the guest's IP (`ip=`, `hyper.ip6=`)."
  @spec guest_args(Lease.t()) :: [String.t()]
  def guest_args(_lease),
    do: raise("Hyper.Node.Net.Ip.guest_args/1 is unimplemented: VM networking is being rewritten")

  @doc "Addresses the VM is reachable at."
  @spec addresses(Lease.t()) :: [:inet.ip_address()]
  def addresses(_lease),
    do: raise("Hyper.Node.Net.Ip.addresses/1 is unimplemented: VM networking is being rewritten")
end
