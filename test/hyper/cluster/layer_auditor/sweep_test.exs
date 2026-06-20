defmodule Hyper.Cluster.LayerAuditor.SweepTest do
  use ExUnit.Case, async: true

  alias Hyper.Cluster.LayerAuditor.Sweep

  # A check_fun stub: present ids map to their actual on-medium size.
  defp checker(sizes) do
    fn id ->
      case Map.fetch(sizes, id) do
        {:ok, size} -> {:ok, size}
        :error -> {:error, :not_found}
      end
    end
  end

  describe "classify/2" do
    test "present when the medium has the file at the expected size" do
      check = checker(%{"a" => 100})
      assert Sweep.classify({"a", 100}, check) == :present
    end

    test "missing when the medium has no file" do
      check = checker(%{})
      assert Sweep.classify({"a", 100}, check) == {:missing, "a", 100}
    end

    test "mismatch when the medium file size differs from the DB" do
      check = checker(%{"a" => 99})
      assert Sweep.classify({"a", 100}, check) == {:mismatch, "a", 100, 99}
    end
  end

  describe "absorb/3" do
    test "tallies outcomes, advances the cursor, and returns per-blob outcomes" do
      check = checker(%{"a" => 1, "c" => 999})
      batch = [{"a", 1}, {"b", 2}, {"c", 1000}]

      {sweep, outcomes} = Sweep.absorb(Sweep.new(), batch, check)

      assert sweep.scanned == 3
      assert sweep.present == 1
      assert sweep.missing == 1
      assert sweep.mismatch == 1
      assert sweep.cursor == "c"
      assert outcomes == [:present, {:missing, "b", 2}, {:mismatch, "c", 1000, 999}]
    end

    test "accumulates across successive batches" do
      check = checker(%{"a" => 1, "b" => 2})
      {s1, _} = Sweep.absorb(Sweep.new(), [{"a", 1}], check)
      {s2, _} = Sweep.absorb(s1, [{"b", 2}], check)

      assert s2.scanned == 2
      assert s2.present == 2
      assert s2.cursor == "b"
    end

    test "an empty batch leaves the cursor untouched" do
      check = checker(%{})
      {s1, _} = Sweep.absorb(Sweep.new(), [{"a", 1}], check)
      {s2, outcomes} = Sweep.absorb(s1, [], check)

      assert s2.cursor == "a"
      assert outcomes == []
    end
  end

  describe "continue?/2" do
    test "true when the batch filled the limit" do
      assert Sweep.continue?([{"a", 1}, {"b", 2}], 2)
    end

    test "false when the batch was short" do
      refute Sweep.continue?([{"a", 1}], 2)
    end

    test "false on an empty batch" do
      refute Sweep.continue?([], 2)
    end
  end
end
