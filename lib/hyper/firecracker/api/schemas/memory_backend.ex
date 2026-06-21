defmodule Hyper.Firecracker.Api.MemoryBackend do
  @moduledoc """
  Provides struct and type for a MemoryBackend
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, backend_path: String.t(), backend_type: String.t()}

  defstruct [:__info__, :backend_path, :backend_type]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [backend_path: :string, backend_type: {:enum, ["File", "Uffd"]}]
  end
end
