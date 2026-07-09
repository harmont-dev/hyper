defmodule Hyper.Firecracker.Api.CodecPropertiesTest do
  @moduledoc """
  Law under test: JSON encode → decode is the identity on generated schema
  structs — `decode(Jason.decode!(Jason.encode!(x))) == x` — for any struct
  whose fields are either set (non-nil) or unset (nil). Encode drops unset
  fields; decode leaves absent keys at the struct default (nil): the two
  halves must cancel exactly, through nested schemas (Drive → RateLimiter →
  TokenBucket) and optional fields at every level.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Firecracker.Api.{Drive, RateLimiter, TokenBucket}

  defp optional(gen), do: one_of([constant(nil), gen])

  defp token_bucket do
    gen all(
          size <- positive_integer(),
          refill_time <- positive_integer(),
          one_time_burst <- optional(positive_integer())
        ) do
      %TokenBucket{size: size, refill_time: refill_time, one_time_burst: one_time_burst}
    end
  end

  defp rate_limiter do
    gen all(
          bandwidth <- optional(token_bucket()),
          ops <- optional(token_bucket())
        ) do
      %RateLimiter{bandwidth: bandwidth, ops: ops}
    end
  end

  defp drive do
    gen all(
          drive_id <- string(:alphanumeric, min_length: 1),
          is_root_device <- boolean(),
          is_read_only <- optional(boolean()),
          path_on_host <- optional(string(:alphanumeric, min_length: 1)),
          cache_type <- optional(member_of(["Unsafe", "Writeback"])),
          rate_limiter <- optional(rate_limiter())
        ) do
      %Drive{
        drive_id: drive_id,
        is_root_device: is_root_device,
        is_read_only: is_read_only,
        path_on_host: path_on_host,
        cache_type: cache_type,
        rate_limiter: rate_limiter
      }
    end
  end

  property "encode → decode is the identity, two schema levels deep" do
    check all(d <- drive()) do
      assert d |> Jason.encode!() |> Jason.decode!() |> Drive.decode() == d
    end
  end
end
