defmodule Hyper.Firecracker.Api.BalloonUpdate do
  @moduledoc """
  Provides struct and type for a BalloonUpdate
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, amount_mib: integer}

  defstruct [:__info__, :amount_mib]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [amount_mib: :integer]
  end
end
