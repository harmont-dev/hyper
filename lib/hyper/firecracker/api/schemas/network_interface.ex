defmodule Hyper.Firecracker.Api.NetworkInterface do
  @moduledoc """
  Provides struct and type for a NetworkInterface
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          guest_mac: String.t() | nil,
          host_dev_name: String.t(),
          iface_id: String.t(),
          mtu: integer | nil,
          rx_rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil,
          tx_rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil
        }

  defstruct [
    :__info__,
    :guest_mac,
    :host_dev_name,
    :iface_id,
    :mtu,
    :rx_rate_limiter,
    :tx_rate_limiter
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      guest_mac: :string,
      host_dev_name: :string,
      iface_id: :string,
      mtu: :integer,
      rx_rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t},
      tx_rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t}
    ]
  end
end
