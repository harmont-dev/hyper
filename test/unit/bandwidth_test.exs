defmodule Unit.BandwidthTest do
  use ExUnit.Case, async: true

  alias Unit.Bandwidth

  test "bps stores bytes-per-second verbatim" do
    assert Bandwidth.as_bytes_per_sec(Bandwidth.bps(512)) == 512
  end

  test "binary-prefix constructors scale by powers of 1024" do
    assert Bandwidth.as_bytes_per_sec(Bandwidth.kibps(1)) == 1024
    assert Bandwidth.as_bytes_per_sec(Bandwidth.mibps(1)) == 1024 * 1024
    assert Bandwidth.as_bytes_per_sec(Bandwidth.gibps(1)) == 1024 * 1024 * 1024
    assert Bandwidth.as_bytes_per_sec(Bandwidth.tibps(1)) == 1024 * 1024 * 1024 * 1024
  end

  test "each prefix is 1024x the prefix below it" do
    assert Bandwidth.kibps(1024) == Bandwidth.mibps(1)
    assert Bandwidth.mibps(1024) == Bandwidth.gibps(1)
    assert Bandwidth.gibps(1024) == Bandwidth.tibps(1)
  end

  test "zero reads back as 0 bytes/sec" do
    assert Bandwidth.as_bytes_per_sec(Bandwidth.zero()) == 0
  end
end
