defmodule Hyper.Firecracker.Api.BalloonHintingStatus do
  @moduledoc """
  Provides struct and type for a BalloonHintingStatus
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, guest_cmd: integer | nil, host_cmd: integer}

  defstruct [:__info__, :guest_cmd, :host_cmd]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [guest_cmd: :integer, host_cmd: :integer]
  end
end
