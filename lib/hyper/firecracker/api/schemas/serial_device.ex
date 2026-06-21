defmodule Hyper.Firecracker.Api.SerialDevice do
  @moduledoc """
  Provides struct and type for a SerialDevice
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          rate_limiter: Hyper.Firecracker.Api.TokenBucket.t() | nil,
          serial_out_path: String.t() | nil
        }

  defstruct [:__info__, :rate_limiter, :serial_out_path]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [rate_limiter: {Hyper.Firecracker.Api.TokenBucket, :t}, serial_out_path: :string]
  end
end
