defmodule Hyper.Vm.Firewall do
  @moduledoc """
  A VM's port policy: the inbound ports open to it and the outbound ports it may
  not use. Every other inbound connection is dropped; every other outbound one is
  allowed.

  Laws (see the property suite):

    * `new/2` accepts exactly the rules whose protocol is `:tcp` or `:udp` and
      whose ports are an ascending range within `1..65535`, at most
      `max_rules/0` per direction, and refuses everything else;
    * `to_request/1` renders the policy the suidhelper's `vm_launch` and
      `vm_firewall` parse, one `[first, last]` pair per rule, in order.
  """

  @max_rules 128

  @type protocol :: :tcp | :udp
  @type rule :: {protocol(), Range.t()}

  @enforce_keys [:inbound, :outbound_blocked]
  defstruct [:inbound, :outbound_blocked]

  @type t :: %__MODULE__{inbound: [rule()], outbound_blocked: [rule()]}

  @doc "Nothing open inbound and nothing blocked outbound."
  @spec default() :: t()
  def default, do: %__MODULE__{inbound: [], outbound_blocked: []}

  @doc "The most rules one direction holds."
  @spec max_rules() :: pos_integer()
  def max_rules, do: @max_rules

  @spec new([rule()], [rule()]) ::
          {:ok, t()} | {:error, {:bad_firewall_rule, term()} | :too_many_firewall_rules}
  def new(inbound, outbound_blocked) when is_list(inbound) and is_list(outbound_blocked) do
    with :ok <- check(inbound),
         :ok <- check(outbound_blocked) do
      {:ok, %__MODULE__{inbound: inbound, outbound_blocked: outbound_blocked}}
    end
  end

  @spec to_request(t()) :: %{inbound: [map()], outbound_blocked: [map()]}
  def to_request(%__MODULE__{inbound: inbound, outbound_blocked: outbound_blocked}) do
    %{
      inbound: Enum.map(inbound, &rule_request/1),
      outbound_blocked: Enum.map(outbound_blocked, &rule_request/1)
    }
  end

  @spec check([term()]) :: :ok | {:error, {:bad_firewall_rule, term()} | :too_many_firewall_rules}
  defp check(rules) when length(rules) > @max_rules, do: {:error, :too_many_firewall_rules}

  defp check(rules) do
    case Enum.reject(rules, &valid_rule?/1) do
      [] -> :ok
      [bad | _] -> {:error, {:bad_firewall_rule, bad}}
    end
  end

  @spec valid_rule?(term()) :: boolean()
  defp valid_rule?({protocol, first..last//1}) when protocol in [:tcp, :udp],
    do: first in 1..65_535 and last in first..65_535//1

  defp valid_rule?(_), do: false

  @spec rule_request(rule()) :: map()
  defp rule_request({protocol, first..last//1}),
    do: %{protocol: Atom.to_string(protocol), ports: [first, last]}
end
