defmodule Sys.Mon.NetBwTest do
  @moduledoc """
  Pure parts of the network-bandwidth monitor: the counter sum `sum_bytes/1` and
  the rate-to-`Unit.Bandwidth` projection `as_bandwidth/1`. The physical-interface
  filtering and `/proc/net/dev` read are I/O and are not exercised here.

  Laws mirror the disk monitor: `sum_bytes` equals an independent reference
  (`Enum.sum` of rx+tx, `[]` -> `0`); `as_bandwidth` rounds the raw bytes/sec
  into a `Bandwidth`, reads back as `round(x)`, threads the opaque `Rate` state
  through untouched, and passes a `:skip` straight through.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Proc.NetDev.Interface
  alias Sys.Mon.NetBw
  alias Unit.Bandwidth

  defp interface do
    gen all(
          name <- string(:alphanumeric, min_length: 1),
          rx <- integer(0..1_000_000_000),
          tx <- integer(0..1_000_000_000)
        ) do
      %Interface{name: name, rx_bytes: rx, tx_bytes: tx}
    end
  end

  property "sum_bytes totals rx+tx across every interface" do
    check all(interfaces <- list_of(interface())) do
      expected = Enum.sum(Enum.map(interfaces, &(&1.rx_bytes + &1.tx_bytes)))
      assert NetBw.sum_bytes(interfaces) == expected
    end
  end

  test "sum_bytes of no interfaces is zero" do
    assert NetBw.sum_bytes([]) == 0
  end

  property "as_bandwidth rounds the rate and preserves the Rate state" do
    check all(
            rate <- float(min: 0.0, max: 1.0e12),
            state <- one_of([constant(nil), tuple({integer(0..1000), integer()})])
          ) do
      assert {:ok, bw, ^state} = NetBw.as_bandwidth({:ok, rate, state})
      assert Bandwidth.as_bytes_per_sec(bw) == round(rate)
    end
  end

  test "as_bandwidth passes a :skip straight through" do
    assert NetBw.as_bandwidth({:skip, {7, 99}}) == {:skip, {7, 99}}
  end
end
