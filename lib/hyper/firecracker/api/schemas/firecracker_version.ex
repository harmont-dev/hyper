defmodule Hyper.Firecracker.Api.FirecrackerVersion do
  @moduledoc """
  Provides struct and type for a FirecrackerVersion
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, firecracker_version: String.t()}

  defstruct [:__info__, :firecracker_version]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [firecracker_version: :string]
  end
end
