defmodule Hyper.Firecracker.Api.MemoryHotplugConfig do
  @moduledoc """
  Provides struct and type for a MemoryHotplugConfig
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          block_size_mib: integer | nil,
          slot_size_mib: integer | nil,
          total_size_mib: integer | nil
        }

  defstruct [:__info__, :block_size_mib, :slot_size_mib, :total_size_mib]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [block_size_mib: :integer, slot_size_mib: :integer, total_size_mib: :integer]
  end
end
