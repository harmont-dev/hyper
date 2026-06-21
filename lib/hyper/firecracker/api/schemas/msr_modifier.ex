defmodule Hyper.Firecracker.Api.MsrModifier do
  @moduledoc """
  Provides struct and type for a MsrModifier
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, addr: String.t(), bitmap: String.t()}

  defstruct [:__info__, :addr, :bitmap]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [addr: :string, bitmap: :string]
  end
end
