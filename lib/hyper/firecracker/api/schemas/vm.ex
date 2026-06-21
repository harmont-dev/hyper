defmodule Hyper.Firecracker.Api.Vm do
  @moduledoc """
  Provides struct and type for a Vm
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, state: String.t()}

  defstruct [:__info__, :state]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [state: {:enum, ["Paused", "Resumed"]}]
  end
end
