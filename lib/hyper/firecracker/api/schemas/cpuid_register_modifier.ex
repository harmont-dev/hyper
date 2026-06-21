defmodule Hyper.Firecracker.Api.CpuidRegisterModifier do
  @moduledoc """
  Provides struct and type for a CpuidRegisterModifier
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, bitmap: String.t(), register: String.t()}

  defstruct [:__info__, :bitmap, :register]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bitmap: :string, register: {:enum, ["eax", "ebx", "ecx", "edx"]}]
  end
end
