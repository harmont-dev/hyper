defmodule Hyper.Node.Reaper.PlanTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Reaper.Plan

  defp set(ids), do: MapSet.new(ids)

  describe "orphans/2" do
    test "orphans are the resource-holding ids outside the live set, each once" do
      rows = [
        {[], ["dead"], ["dead"]},
        {[], ["dead", "dead"], ["dead"]},
        {["alive"], ["alive", "alive"], []},
        {["alive"], ["alive", "dead", "gone"], ["dead", "gone"]}
      ]

      for {live, held, orphans} <- rows do
        assert Plan.orphans(set(live), held) == set(orphans), inspect({live, held})
      end
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

  test "netns_ids/1 strips the hyper- prefix and ignores other namespaces" do
    assert Plan.netns_ids(["hyper-vabc", "cni-1234", "vabc"]) == ["vabc"]
  end
end
