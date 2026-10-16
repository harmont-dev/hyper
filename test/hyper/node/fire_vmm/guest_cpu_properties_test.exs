defmodule Hyper.Node.FireVMM.GuestCpuPropertiesTest do
  @moduledoc """
  Laws for `GuestCpu.config(:x86_64)`, checked by applying its modifiers to
  arbitrary host CPUID values the way Firecracker documents the bitmap (`0b` +
  32 chars, bit 31 first; `0` clears, `1` sets, `x` keeps):

    * masked -- VMX (`CPUID.01H:ECX[5]`) and SVM (`CPUID.80000001H:ECX[2]`)
      are clear in the guest for every host value;
    * minimal -- every other bit keeps the host's value, and no modifier
      targets a leaf, subleaf or register outside those two.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Bitwise

  alias Hyper.Firecracker.Api.{CpuidLeafModifier, CpuidRegisterModifier}
  alias Hyper.Node.FireVMM.GuestCpu

  @u32 0..0xFFFF_FFFF

  property "VMX and SVM are cleared and every other host bit survives" do
    check all(leaf_1_ecx <- integer(@u32), ext_leaf_1_ecx <- integer(@u32)) do
      host = %{{0x1, 0, :ecx} => leaf_1_ecx, {0x80000001, 0, :ecx} => ext_leaf_1_ecx}

      guest = apply_modifiers(host, GuestCpu.config(:x86_64).cpuid_modifiers)

      assert guest == %{
               {0x1, 0, :ecx} => leaf_1_ecx &&& bnot(1 <<< 5),
               {0x80000001, 0, :ecx} => ext_leaf_1_ecx &&& bnot(1 <<< 2)
             }
    end
  end

  # A modifier for a register the host table lacks raises, so a stray leaf,
  # subleaf or register fails the property rather than slipping past it.
  defp apply_modifiers(host, modifiers) do
    for %CpuidLeafModifier{leaf: leaf, subleaf: subleaf, modifiers: regs} <- modifiers,
        %CpuidRegisterModifier{register: register, bitmap: bitmap} <- regs,
        reduce: host do
      acc ->
        key = {parse_index(leaf), parse_index(subleaf), String.to_existing_atom(register)}
        Map.update!(acc, key, &apply_bitmap(bitmap, &1))
    end
  end

  defp apply_bitmap("0b" <> bits, value) when byte_size(bits) == 32 do
    bits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.with_index()
    |> Enum.reduce(value, fn
      {"x", _bit}, acc -> acc
      {"0", bit}, acc -> acc &&& bnot(1 <<< bit)
      {"1", bit}, acc -> acc ||| 1 <<< bit
    end)
  end

  defp parse_index("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_index("0b" <> bin), do: String.to_integer(bin, 2)
  defp parse_index(dec), do: String.to_integer(dec)
end
