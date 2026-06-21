defmodule Hyper.Firecracker.Api.PartialNetworkInterface do
  @moduledoc """
  Provides struct and type for a PartialNetworkInterface
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          iface_id: String.t(),
          rx_rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil,
          tx_rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil
        }

  defstruct [:__info__, :iface_id, :rx_rate_limiter, :tx_rate_limiter]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      iface_id: :string,
      rx_rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t},
      tx_rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t}
    ]
  end
end
