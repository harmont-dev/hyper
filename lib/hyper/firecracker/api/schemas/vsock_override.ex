defmodule Hyper.Firecracker.Api.VsockOverride do
  @moduledoc """
  Provides struct and type for a VsockOverride
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, uds_path: String.t()}

  defstruct [:__info__, :uds_path]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [uds_path: :string]
  end
end
