defmodule Hyper.Firecracker.Api.CpuidLeafModifier do
  @moduledoc """
  Provides struct and type for a CpuidLeafModifier
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          flags: integer,
          leaf: String.t(),
          modifiers: [Hyper.Firecracker.Api.CpuidRegisterModifier.t()],
          subleaf: String.t()
        }

  defstruct [:__info__, :flags, :leaf, :modifiers, :subleaf]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      flags: {:integer, "int32"},
      leaf: :string,
      modifiers: [{Hyper.Firecracker.Api.CpuidRegisterModifier, :t}],
      subleaf: :string
    ]
  end
end
