defmodule Hyper.Firecracker.Api.NetworkOverride do
  @moduledoc """
  Provides struct and type for a NetworkOverride
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, host_dev_name: String.t(), iface_id: String.t()}

  defstruct [:__info__, :host_dev_name, :iface_id]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [host_dev_name: :string, iface_id: :string]
  end
end
