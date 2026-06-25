defmodule Sys.Mon.DiskBwTest do
  @moduledoc """
  Pure parts of the disk-bandwidth monitor: the counter sum `sum_bytes/1` and
  the rate-to-`Unit.Bandwidth` projection `as_bandwidth/1`. The physical-device
  filtering and `/proc/diskstats` read are I/O and are not exercised here.

  Laws:

    * `sum_bytes` equals an independent reference (`Enum.sum` of read+write) -
      an oracle, with `[]` summing to `0`.
    * `as_bandwidth` rounds the raw bytes/sec into a `Bandwidth`, reads back as
      `round(x)`, and threads the opaque `Rate` state through untouched; a
      `:skip` (no baseline yet) passes straight through.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Proc.Diskstats.Device
  alias Sys.Mon.DiskBw
  alias Unit.Bandwidth

  defp device do
    gen all(
          name <- string(:alphanumeric, min_length: 1),
          read <- integer(0..1_000_000_000),
          write <- integer(0..1_000_000_000)
        ) do
      %Device{name: name, read_bytes: read, write_bytes: write}
    end
  end

  property "sum_bytes totals read+write across every device" do
    check all(devices <- list_of(device())) do
      expected = Enum.sum(Enum.map(devices, &(&1.read_bytes + &1.write_bytes)))
      assert DiskBw.sum_bytes(devices) == expected
    end
  end

  test "sum_bytes of no devices is zero" do
    assert DiskBw.sum_bytes([]) == 0
  end

  property "as_bandwidth rounds the rate and preserves the Rate state" do
    check all(
            rate <- float(min: 0.0, max: 1.0e12),
            state <- one_of([constant(nil), tuple({integer(0..1000), integer()})])
          ) do
      assert {:ok, bw, ^state} = DiskBw.as_bandwidth({:ok, rate, state})
      assert Bandwidth.as_bytes_per_sec(bw) == round(rate)
    end
  end

  test "as_bandwidth passes a :skip straight through" do
    assert DiskBw.as_bandwidth({:skip, {7, 99}}) == {:skip, {7, 99}}
  end
end
