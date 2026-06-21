defmodule Hyper.Firecracker.Api.BalloonStartCmd do
  @moduledoc """
  Provides struct and type for a BalloonStartCmd
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, acknowledge_on_stop: boolean | nil}

  defstruct [:__info__, :acknowledge_on_stop]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [acknowledge_on_stop: :boolean]
  end
end
