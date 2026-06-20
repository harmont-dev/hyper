defmodule Controls.EwmaTest do
  use ExUnit.Case, async: true

  alias Controls.Ewma
  alias Unit.Information

  # tau chosen so that 1 - exp(-dt/tau) == 0.5 at dt == 1000 ms.
  @tau_half round(1000 / :math.log(2))

  describe "with floats" do
    test "value/1 is nil before any sample" do
      assert Ewma.value(Ewma.new(1000)) == nil
    end

    test "seeds with the first sample (no warm-up ramp from zero)" do
      e = Ewma.new(1000) |> Ewma.update(0.5, 200)
      assert Ewma.value(e) == 0.5
    end

    test "equal dt with an alpha=0.5 tau halves toward the new sample" do
      e = Ewma.new(@tau_half) |> Ewma.update(0.0, 1000) |> Ewma.update(1.0, 1000)
      assert_in_delta Ewma.value(e), 0.5, 0.001
    end

    test "a sample after ~3 tau reaches ~95% of a unit step" do
      e = Ewma.new(1000) |> Ewma.update(0.0, 1000) |> Ewma.update(1.0, 3000)
      assert_in_delta Ewma.value(e), 0.95, 0.01
    end
  end

  describe "with a non-float Controls.Linear type (Unit.Information)" do
    test "seeds with the first Information sample, unchanged" do
      e = Ewma.new(1000) |> Ewma.update(Information.kib(100), 200)
      assert Ewma.value(e) == Information.kib(100)
    end

    test "filters via scale/add and stays an Information" do
      e =
        Ewma.new(@tau_half)
        |> Ewma.update(Information.bytes(0), 1000)
        |> Ewma.update(Information.bytes(1000), 1000)

      # 0.5*1000 + 0.5*0 = 500 bytes
      assert Ewma.value(e) == Information.bytes(500)
    end
  end
end
