defmodule Hyper.Firecracker.Api.RateLimiter do
  @moduledoc """
  Provides struct and type for a RateLimiter
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          bandwidth: Hyper.Firecracker.Api.TokenBucket.t() | nil,
          ops: Hyper.Firecracker.Api.TokenBucket.t() | nil
        }

  defstruct [:__info__, :bandwidth, :ops]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      bandwidth: {Hyper.Firecracker.Api.TokenBucket, :t},
      ops: {Hyper.Firecracker.Api.TokenBucket, :t}
    ]
  end
end
