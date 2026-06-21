defmodule Hyper.Firecracker.Api.Pmem do
  @moduledoc """
  Provides struct and type for a Pmem
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          id: String.t(),
          path_on_host: String.t(),
          rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil,
          read_only: boolean | nil,
          root_device: boolean | nil
        }

  defstruct [:__info__, :id, :path_on_host, :rate_limiter, :read_only, :root_device]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      id: :string,
      path_on_host: :string,
      rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t},
      read_only: :boolean,
      root_device: :boolean
    ]
  end
end
