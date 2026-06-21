defmodule Hyper.Firecracker.Api.VcpuFeatures do
  @moduledoc """
  Provides struct and type for a VcpuFeatures
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, bitmap: String.t(), index: integer}

  defstruct [:__info__, :bitmap, :index]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [bitmap: :string, index: {:integer, "int32"}]
  end
end
