defmodule Controls.LinearTest do
  use ExUnit.Case, async: true

  alias Controls.Linear
  alias Unit.Bandwidth
  alias Unit.Information

  describe "Float" do
    test "scale/2 multiplies, add/2 sums, to_float/1 is identity" do
      assert Linear.scale(4.0, 0.25) == 1.0
      assert Linear.add(1.5, 2.5) == 4.0
      assert Linear.to_float(3.0) == 3.0
    end
  end

  describe "Unit.Information" do
    test "scale/2 rounds bytes, add/2 sums bytes, stays an Information" do
      assert Linear.scale(Information.bytes(1000), 0.3) == Information.bytes(300)
      assert Linear.add(Information.bytes(700), Information.bytes(300)) == Information.bytes(1000)
    end

    test "to_float/1 yields the byte magnitude" do
      assert Linear.to_float(Information.kib(1)) == 1024.0
    end
  end

  describe "Unit.Bandwidth" do
    test "scale/2 rounds bytes/sec, add/2 sums, stays a Bandwidth" do
      assert Linear.scale(Bandwidth.bps(1000), 0.5) == Bandwidth.bps(500)
      assert Linear.add(Bandwidth.bps(250), Bandwidth.bps(250)) == Bandwidth.bps(500)
    end

    test "to_float/1 yields the bytes-per-second magnitude" do
      assert Linear.to_float(Bandwidth.kibps(1)) == 1024.0
    end
  end
end
