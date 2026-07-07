defmodule Sys.Linux.Cgroup.V2.CpuStatPropertiesTest do
  @moduledoc """
  Laws for the `cpu.stat` parser: a rendered payload round-trips its
  `usage_usec`/`user_usec`/`system_usec` regardless of line order or unknown
  interleaved lines; and a payload without `usage_usec` is always refused —
  the billing counter must never silently read as zero.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Cgroup.V2.CpuStat
  alias Unit.Time

  defp counter, do: integer(0..1_000_000_000_000)

  defp noise_line do
    gen all(
          key <- member_of(~w(nr_periods nr_throttled throttled_usec nr_bursts burst_usec)),
          value <- counter()
        ) do
      "#{key} #{value}"
    end
  end

  property "a reordered payload with noise round-trips the three time counters" do
    check all(
            usage <- counter(),
            user <- counter(),
            system <- counter(),
            noise <- list_of(noise_line(), max_length: 6),
            rotation <- integer(0..8)
          ) do
      lines = ["usage_usec #{usage}", "user_usec #{user}", "system_usec #{system}" | noise]
      # A deterministic rotation: order-independence is under test, not randomness.
      {head, tail} = Enum.split(lines, rem(rotation, length(lines)))
      content = Enum.join(tail ++ head, "\n")

      assert {:ok, parsed} = CpuStat.parse(content)
      assert Time.as_us(parsed.usage) == usage
      assert Time.as_us(parsed.user) == user
      assert Time.as_us(parsed.system) == system
    end
  end

  property "any payload without usage_usec is refused" do
    check all(noise <- list_of(noise_line(), max_length: 6), user <- counter()) do
      content = Enum.join(["user_usec #{user}" | noise], "\n")
      assert {:error, :missing_usage} = CpuStat.parse(content)
    end
  end
end
