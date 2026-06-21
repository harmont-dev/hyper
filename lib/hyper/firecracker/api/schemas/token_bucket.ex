defmodule Hyper.Firecracker.Api.TokenBucket do
  @moduledoc """
  Provides struct and type for a TokenBucket
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          one_time_burst: integer | nil,
          refill_time: integer,
          size: integer
        }

  defstruct [:__info__, :one_time_burst, :refill_time, :size]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      one_time_burst: {:integer, "int64"},
      refill_time: {:integer, "int64"},
      size: {:integer, "int64"}
    ]
  end
end
