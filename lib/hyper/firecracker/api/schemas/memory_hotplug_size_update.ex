defmodule Hyper.Firecracker.Api.MemoryHotplugSizeUpdate do
  @moduledoc """
  Provides struct and type for a MemoryHotplugSizeUpdate
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, requested_size_mib: integer | nil}

  defstruct [:__info__, :requested_size_mib]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [requested_size_mib: :integer]
  end
end
