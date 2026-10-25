defmodule Hyper.Node.Net.Ip.Host do
  @moduledoc "The IP layer's host-wide facts, from `net ip host-init`."

  @typedoc "An address prefix: network address plus prefix length."
  @type prefix :: {:inet.ip_address(), non_neg_integer()}

  @enforce_keys [:uplink, :transit_prefix, :vm_prefix]
  defstruct [:uplink, :transit_prefix, :vm_prefix]

  @type t :: %__MODULE__{uplink: String.t(), transit_prefix: prefix(), vm_prefix: prefix()}
end
