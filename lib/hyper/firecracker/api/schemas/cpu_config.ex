defmodule Hyper.Firecracker.Api.CpuConfig do
  @moduledoc """
  Provides struct and type for a CpuConfig
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          cpuid_modifiers: [Hyper.Firecracker.Api.CpuidLeafModifier.t()] | nil,
          kvm_capabilities: [String.t()] | nil,
          msr_modifiers: [Hyper.Firecracker.Api.MsrModifier.t()] | nil,
          reg_modifiers: [Hyper.Firecracker.Api.ArmRegisterModifier.t()] | nil,
          vcpu_features: [Hyper.Firecracker.Api.VcpuFeatures.t()] | nil
        }

  defstruct [
    :__info__,
    :cpuid_modifiers,
    :kvm_capabilities,
    :msr_modifiers,
    :reg_modifiers,
    :vcpu_features
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      cpuid_modifiers: [{Hyper.Firecracker.Api.CpuidLeafModifier, :t}],
      kvm_capabilities: [:string],
      msr_modifiers: [{Hyper.Firecracker.Api.MsrModifier, :t}],
      reg_modifiers: [{Hyper.Firecracker.Api.ArmRegisterModifier, :t}],
      vcpu_features: [{Hyper.Firecracker.Api.VcpuFeatures, :t}]
    ]
  end
end
