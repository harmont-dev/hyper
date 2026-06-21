defmodule Hyper.Firecracker.Api.EntropyDevice do
  @moduledoc """
  Provides struct and type for a EntropyDevice
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{__info__: map, rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil}

  defstruct [:__info__, :rate_limiter]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t}]
  end
end
