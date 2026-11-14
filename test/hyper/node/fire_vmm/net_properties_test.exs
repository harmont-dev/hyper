defmodule Hyper.Node.FireVMM.NetPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Node.FireVMM.Net

  property "every guest MAC is a full six-octet locally-administered unicast address" do
    check all(vm_id <- string(:alphanumeric, min_length: 1)) do
      octets = vm_id |> Net.guest_mac() |> String.split(":")

      assert length(octets) == 6
      assert Enum.all?(octets, &(&1 =~ ~r/\A[0-9a-f]{2}\z/))

      first = octets |> hd() |> String.to_integer(16)
      assert (first &&& 0b10) == 0b10
      assert (first &&& 0b01) == 0
    end
  end
end
