defmodule Hyper.Vm.Firewall do
  @moduledoc """
  A VM's port policy: the inbound ports open to it and the outbound ports it may
  not use. Every other inbound connection is dropped; every other outbound one is
  allowed.

  `to_request/1` renders the policy the suidhelper's `vm_launch` parses, one
  `[first, last]` pair per rule, in order.
  """

  @type protocol :: :tcp | :udp
  @type rule :: {protocol(), Range.t()}

  @enforce_keys [:inbound, :outbound_blocked]
  defstruct [:inbound, :outbound_blocked]

  @type t :: %__MODULE__{inbound: [rule()], outbound_blocked: [rule()]}

  @doc "Nothing open inbound and nothing blocked outbound."
  @spec default() :: t()
  def default, do: %__MODULE__{inbound: [], outbound_blocked: []}

  @spec to_request(t()) :: %{inbound: [map()], outbound_blocked: [map()]}
  def to_request(%__MODULE__{inbound: inbound, outbound_blocked: outbound_blocked}) do
    %{
      inbound: Enum.map(inbound, &rule_request/1),
      outbound_blocked: Enum.map(outbound_blocked, &rule_request/1)
    }
  end

  @spec rule_request(rule()) :: map()
  defp rule_request({protocol, first..last//1}),
    do: %{protocol: Atom.to_string(protocol), ports: [first, last]}
end
