defmodule Hyper.Firecracker.Api.PartialDrive do
  @moduledoc """
  Provides struct and type for a PartialDrive
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          drive_id: String.t(),
          path_on_host: String.t() | nil,
          rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil
        }

  defstruct [:__info__, :drive_id, :path_on_host, :rate_limiter]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      drive_id: :string,
      path_on_host: :string,
      rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t}
    ]
  end
end
