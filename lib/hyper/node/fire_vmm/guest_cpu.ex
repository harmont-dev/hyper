defmodule Hyper.Node.FireVMM.GuestCpu do
  @moduledoc """
  The CPU features a guest boots with.

  Guests never see a hardware-virtualization extension. Firecracker passes VMX
  and SVM through from the host unmasked, so on a host whose KVM offers nested
  virt (the `kvm_intel`/`kvm_amd` default) every guest could run its own
  hypervisor on top of the host's nested-paging code (CVE-2026-53359). KVM
  refuses CR4.VMXE and EFER.SVME when the guest's CPUID lacks the bit, so the
  mask holds whatever the host's `nested` parameter says.
  """

  alias Hyper.Firecracker.Api.{CpuConfig, CpuidLeafModifier, CpuidRegisterModifier}

  @vmx_leaf "0x1"
  @vmx_ecx_bit 5
  @svm_leaf "0x80000001"
  @svm_ecx_bit 2

  @doc "The `/cpu-config` for an `arch` guest, or `nil` on aarch64 (CPUID modifiers are x86_64-only)."
  @spec config(Sys.Arch.t()) :: CpuConfig.t() | nil
  def config(:aarch64), do: nil

  def config(:x86_64) do
    %CpuConfig{
      cpuid_modifiers: [
        clear_ecx_bit(@vmx_leaf, @vmx_ecx_bit),
        clear_ecx_bit(@svm_leaf, @svm_ecx_bit)
      ]
    }
  end

  # Firecracker's bitmap is `0b` + 32 chars, bit 31 first: `0` clears, `1` sets,
  # `x` keeps the host's value.
  @spec clear_ecx_bit(String.t(), 0..31) :: CpuidLeafModifier.t()
  defp clear_ecx_bit(leaf, bit) do
    bitmap = String.duplicate("x", 31 - bit) <> "0" <> String.duplicate("x", bit)

    %CpuidLeafModifier{
      leaf: leaf,
      subleaf: "0x0",
      flags: 0,
      modifiers: [%CpuidRegisterModifier{register: "ecx", bitmap: "0b" <> bitmap}]
    }
  end
end
