defmodule Controls.RatePropertiesTest do
  @moduledoc """
  `Controls.Rate.compute/3` is a pure state machine. These properties pin every
  branch: the three conditions that must yield `:skip` (re-baselining without
  emitting a meaningless rate), and the arithmetic of the one `:ok` branch.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Controls.Rate

  defp count, do: integer(0..1_000_000_000)
  defp mono, do: integer(-1_000_000..1_000_000)

  property "the first observation (nil state) always skips and seeds the baseline" do
    check all(c <- count(), t <- mono()) do
      assert Rate.compute(nil, c, t) == {:skip, {c, t}}
    end
  end

  property "a counter that went backwards skips and re-baselines to the new reading" do
    check all(
            prev_c <- count(),
            prev_t <- mono(),
            drop <- integer(1..prev_c//1),
            t <- mono()
          ) do
      c = prev_c - drop
      assert c < prev_c
      assert Rate.compute({prev_c, prev_t}, c, t) == {:skip, {c, t}}
    end
  end

  property "a non-positive dt skips (no division by a stale or reversed clock)" do
    check all(
            prev_c <- count(),
            prev_t <- mono(),
            extra <- count(),
            back <- integer(0..1_000_000)
          ) do
      c = prev_c + extra
      t = prev_t - back
      assert t <= prev_t
      assert Rate.compute({prev_c, prev_t}, c, t) == {:skip, {c, t}}
    end
  end

  property "a forward counter over positive dt yields the exact non-negative rate" do
    check all(
            prev_c <- count(),
            prev_t <- mono(),
            gain <- count(),
            dt <- integer(1..1_000_000)
          ) do
      c = prev_c + gain
      t = prev_t + dt
      assert {:ok, rate, {^c, ^t}} = Rate.compute({prev_c, prev_t}, c, t)
      assert rate == gain * 1000.0 / dt
      assert rate >= 0.0
    end
  end

  property "at a fixed dt, a larger counter delta never produces a smaller rate" do
    check all(
            prev_c <- count(),
            prev_t <- mono(),
            g1 <- count(),
            g2 <- count(),
            dt <- integer(1..1_000_000)
          ) do
      t = prev_t + dt
      {:ok, r1, _} = Rate.compute({prev_c, prev_t}, prev_c + g1, t)
      {:ok, r2, _} = Rate.compute({prev_c, prev_t}, prev_c + g2, t)
      if g1 <= g2, do: assert(r1 <= r2), else: assert(r1 >= r2)
    end
  end
end
