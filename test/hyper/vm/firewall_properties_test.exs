defmodule Hyper.Vm.FirewallPropertiesTest do
  @moduledoc """
  Laws of `Hyper.Vm.Firewall`:

    * `new/2` accepts every rule list of `:tcp`/`:udp` rules over ascending
      ranges within `1..65535`, up to `max_rules/0` per direction;
    * it refuses a list holding any rule outside that, naming the rule, and any
      direction past `max_rules/0`;
    * `to_request/1` renders each rule as its protocol name and `[first, last]`,
      in order (the shape the suidhelper parses).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Vm.Firewall

  defp port, do: integer(1..65_535)

  defp rule do
    gen all(
          protocol <- member_of([:tcp, :udp]),
          first <- port(),
          last <- integer(first..65_535)
        ) do
      {protocol, first..last//1}
    end
  end

  defp rules, do: list_of(rule(), max_length: Firewall.max_rules())

  defp bad_rule do
    one_of([
      map(port(), &{:icmp, &1..&1//1}),
      map(port(), &{:tcp, 0..&1//1}),
      map(integer(65_536..131_072), &{:udp, 1..&1//1}),
      gen(
        all(
          first <- integer(2..65_535),
          last <- integer(1..(first - 1)),
          do: {:tcp, first..last//-1}
        )
      ),
      constant(:tcp),
      constant({:tcp, 22})
    ])
  end

  property "valid rules within the limit are accepted as given" do
    check all(inbound <- rules(), outbound_blocked <- rules()) do
      assert {:ok, %Firewall{inbound: ^inbound, outbound_blocked: ^outbound_blocked}} =
               Firewall.new(inbound, outbound_blocked)
    end
  end

  property "one bad rule anywhere refuses the policy, naming it" do
    check all(
            good <- list_of(rule(), max_length: 8),
            bad <- bad_rule(),
            at <- integer(0..length(good)),
            inbound? <- boolean()
          ) do
      tainted = List.insert_at(good, at, bad)
      {inbound, outbound_blocked} = if inbound?, do: {tainted, good}, else: {good, tainted}

      assert Firewall.new(inbound, outbound_blocked) == {:error, {:bad_firewall_rule, bad}}
    end
  end

  property "a direction past the limit is refused" do
    check all(
            extra <- integer(1..8),
            rule <- rule(),
            inbound? <- boolean()
          ) do
      over = List.duplicate(rule, Firewall.max_rules() + extra)
      {inbound, outbound_blocked} = if inbound?, do: {over, []}, else: {[], over}

      assert Firewall.new(inbound, outbound_blocked) == {:error, :too_many_firewall_rules}
    end
  end

  property "the request renders each rule as protocol and [first, last], in order" do
    check all(inbound <- rules(), outbound_blocked <- rules()) do
      {:ok, firewall} = Firewall.new(inbound, outbound_blocked)
      wire = fn {protocol, first..last//1} -> %{protocol: "#{protocol}", ports: [first, last]} end

      assert Firewall.to_request(firewall) == %{
               inbound: Enum.map(inbound, wire),
               outbound_blocked: Enum.map(outbound_blocked, wire)
             }
    end
  end
end
