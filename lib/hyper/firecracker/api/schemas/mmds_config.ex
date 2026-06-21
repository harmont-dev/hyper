defmodule Hyper.Firecracker.Api.MmdsConfig do
  @moduledoc """
  Provides struct and type for a MmdsConfig
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          imds_compat: boolean | nil,
          ipv4_address: String.t() | nil,
          network_interfaces: [String.t()],
          version: String.t() | nil
        }

  defstruct [:__info__, :imds_compat, :ipv4_address, :network_interfaces, :version]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      imds_compat: :boolean,
      ipv4_address:
        {:string,
         "169.254.([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-4]).([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])"},
      network_interfaces: [:string],
      version: {:enum, ["V1", "V2"]}
    ]
  end
end
