defmodule Hyper.Firecracker.Api.PartialPmem do
  @moduledoc """
  Provides struct and type for a PartialPmem
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          id: String.t(),
          rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil
        }

  defstruct [:__info__, :id, :rate_limiter]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [id: :string, rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t}]
  end
end
