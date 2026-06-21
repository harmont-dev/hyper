defmodule Hyper.Firecracker.Api.Error do
  @moduledoc """
  Provides struct and type for a Error
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, fault_message: String.t() | nil}

  defstruct [:__info__, :fault_message]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [fault_message: :string]
  end
end
