defmodule Hyper.Node.Reaper.PlanTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Reaper.Plan

  defp set(ids), do: MapSet.new(ids)

  describe "orphans/3" do
    test "a cgroup-leaf-only orphan is a candidate" do
      assert Plan.orphans(set([]), ["dead"], []) == set(["dead"])
    end

    test "a dm-only orphan is a candidate" do
      assert Plan.orphans(set([]), [], ["dead"]) == set(["dead"])
    end

    test "an id seen in both sources is a single candidate" do
      assert Plan.orphans(set([]), ["dead"], ["dead"]) == set(["dead"])
    end

    test "an id present in live is never a candidate, even if it also has resources" do
      assert Plan.orphans(set(["alive"]), ["alive"], ["alive"]) == set([])
    end

    test "only the non-live ids survive as candidates" do
      assert Plan.orphans(set(["alive"]), ["alive", "dead"], ["alive", "gone"]) ==
               set(["dead", "gone"])
    end
  end

  describe "confirm/2 two-strike grace" do
    test "first tick reaps nothing (last is empty) but remembers the candidates" do
      current = set(["x", "y"])
      {reap, next} = Plan.confirm(current, set([]))

      assert reap == set([])
      assert next == current
    end

    test "second tick reaps the still-orphan ids" do
      {_, last} = Plan.confirm(set(["x", "y"]), set([]))
      {reap, _next} = Plan.confirm(set(["x", "y"]), last)

      assert reap == set(["x", "y"])
    end

    test "an id orphaned tick1 but live/absent tick2 is not reaped" do
      {_, last} = Plan.confirm(set(["x"]), set([]))
      {reap, _next} = Plan.confirm(set([]), last)

      assert reap == set([])
    end

    test "an id new in tick2 is not reaped (only one strike)" do
      {_, last} = Plan.confirm(set(["x"]), set([]))
      {reap, _next} = Plan.confirm(set(["x", "fresh"]), last)

      assert reap == set(["x"])
    end
  end

  test "rw_ids/1 strips the hyper-rw- prefix and ignores thinpool/img names" do
    assert Plan.rw_ids(["hyper-thinpool", "hyper-img-abc-0", "hyper-rw-vabc"]) == ["vabc"]
  end
end
