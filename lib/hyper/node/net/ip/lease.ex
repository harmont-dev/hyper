defmodule Hyper.Node.Net.Ip.Lease do
  @moduledoc """
  One VM's IP link, from `net ip prepare`:

    * `host_veth` - the host end of the VM's veth pair.
    * `ipv4` - uplink address in `transit_prefix`.
    * `ipv6` - the guest's public adress within the `vm_prefix` subrange
  """

  @enforce_keys [:host_veth, :ipv4, :ipv6]
  defstruct [:host_veth, :ipv4, :ipv6]

  @type t :: %__MODULE__{
          host_veth: String.t(),
          ipv4: :inet.ip4_address(),
          ipv6: :inet.ip6_address()
        }
end
