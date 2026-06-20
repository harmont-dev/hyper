defmodule Hyper.Img.Db.Gc.SweepTest do
  use ExUnit.Case, async: true

  alias Hyper.Img.Db.Gc.Sweep

  # check_fun stub: classify ids by an explicit map; default :present.
  defp probe(map) do
    fn id -> Map.get(map, id, :present) end
  end

  describe "absorb/3" do
    test "splits present vs missing, advances cursor, returns missing {id, size}" do
      check = probe(%{"b" => :missing})
      batch = [{"a", 1}, {"b", 2}, {"c", 3}]

      {sweep, missing} = Sweep.absorb(Sweep.new(), batch, check)

      assert sweep.scanned == 3
      assert sweep.present == 2
      assert sweep.missing == 1
      assert sweep.cursor == "c"
      assert missing == [{"b", 2}]
    end

    test "unknown rows are counted but never returned for pruning" do
      check = probe(%{"a" => :unknown, "b" => :missing})
      batch = [{"a", 1}, {"b", 2}, {"c", 3}]

      {sweep, missing} = Sweep.absorb(Sweep.new(), batch, check)

      assert sweep.present == 1
      assert sweep.missing == 1
      assert sweep.unknown == 1
      assert missing == [{"b", 2}]
    end

    test "accumulates across successive pages" do
      check = probe(%{"a" => :missing, "b" => :missing})
      {s1, m1} = Sweep.absorb(Sweep.new(), [{"a", 1}], check)
      {s2, m2} = Sweep.absorb(s1, [{"b", 2}], check)

      assert s2.scanned == 2
      assert s2.missing == 2
      assert s2.cursor == "b"
      assert m1 == [{"a", 1}]
      assert m2 == [{"b", 2}]
    end

    test "an empty page leaves the cursor untouched and returns no missing" do
      check = probe(%{"a" => :missing})
      {s1, _} = Sweep.absorb(Sweep.new(), [{"a", 1}], check)
      {s2, missing} = Sweep.absorb(s1, [], check)

      assert s2.cursor == "a"
      assert missing == []
    end
  end

  describe "record_prune/4" do
    test "bumps pruned, pruned_bytes and dangling counters" do
      sweep =
        Sweep.new()
        |> Sweep.record_prune(2, 500, 1)
        |> Sweep.record_prune(1, 250, 0)

      assert sweep.pruned == 3
      assert sweep.pruned_bytes == 750
      assert sweep.dangling == 1
    end
  end

  describe "continue?/2" do
    test "true when the page filled the limit" do
      assert Sweep.continue?([{"a", 1}, {"b", 2}], 2)
    end

    test "false when the page was short" do
      refute Sweep.continue?([{"a", 1}], 2)
    end

    test "false on an empty page" do
      refute Sweep.continue?([], 2)
    end
  end
end
