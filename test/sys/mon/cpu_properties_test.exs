defmodule Sys.Mon.CpuPropertiesTest do
  @moduledoc """
  Laws of the busy-fraction calculation `Sys.Mon.Cpu.utilization/2`, the only
  non-trivial logic in the CPU monitor (the rest is `/proc/stat` I/O).

  Laws under test:

    * **Bounded invariant** - the result is *always* in `0.0..1.0`, for any pair
      of `CpuTimes`, even ones whose counters appear to move backwards. The
      clamp must make an out-of-range reading impossible.
    * **Zero-interval refusal** - identical snapshots (no elapsed jiffies) yield
      `0.0`, never a divide-by-zero.
    * **Oracle, fully idle** - an interval whose every elapsed jiffy landed in
      `idle`/`iowait` is `0.0` busy.
    * **Oracle, fully busy** - an interval with no idle increase but some work
      done is `1.0` busy.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Proc.Stat.CpuTimes
  alias Sys.Mon.Cpu

  # A CpuTimes from ten independent non-negative jiffy columns.
  defp cpu_times do
    gen all(cols <- list_of(integer(0..1_000_000), length: 10)) do
      CpuTimes.from_columns(cols)
    end
  end

  property "utilization is always within 0.0..1.0" do
    check all(earlier <- cpu_times(), later <- cpu_times()) do
      u = Cpu.utilization(earlier, later)
      assert u >= 0.0 and u <= 1.0
    end
  end

  property "a zero-length interval (identical snapshots) is 0.0, not a crash" do
    check all(times <- cpu_times()) do
      assert Cpu.utilization(times, times) == 0.0
    end
  end

  property "an interval spent entirely idle is 0.0 busy" do
    check all(
            earlier <- cpu_times(),
            d_idle <- integer(1..1_000_000),
            d_iowait <- integer(0..1_000_000)
          ) do
      later = %{earlier | idle: earlier.idle + d_idle, iowait: earlier.iowait + d_iowait}
      assert Cpu.utilization(earlier, later) == 0.0
    end
  end

  property "an interval with work done but no idle increase is 1.0 busy" do
    check all(earlier <- cpu_times(), d_user <- integer(1..1_000_000)) do
      later = %{earlier | user: earlier.user + d_user}
      assert Cpu.utilization(earlier, later) == 1.0
    end
  end
end
