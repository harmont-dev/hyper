defmodule Hyper.Firecracker.Api.Drive do
  @moduledoc """
  Provides struct and type for a Drive
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          cache_type: String.t() | nil,
          drive_id: String.t(),
          io_engine: String.t() | nil,
          is_read_only: boolean | nil,
          is_root_device: boolean,
          partuuid: String.t() | nil,
          path_on_host: String.t() | nil,
          rate_limiter: Hyper.Firecracker.Api.RateLimiter.t() | nil,
          socket: String.t() | nil
        }

  defstruct [
    :__info__,
    :cache_type,
    :drive_id,
    :io_engine,
    :is_read_only,
    :is_root_device,
    :partuuid,
    :path_on_host,
    :rate_limiter,
    :socket
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      cache_type: {:enum, ["Unsafe", "Writeback"]},
      drive_id: :string,
      io_engine: {:enum, ["Sync", "Async"]},
      is_read_only: :boolean,
      is_root_device: :boolean,
      partuuid: :string,
      path_on_host: :string,
      rate_limiter: {Hyper.Firecracker.Api.RateLimiter, :t},
      socket: :string
    ]
  end
end
