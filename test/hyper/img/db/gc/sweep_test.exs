defmodule Hyper.Img.Db.Gc.SweepTest do
  use ExUnit.Case, async: true

  alias Hyper.Img.Db.Gc.Sweep

  # The one invariant worth pinning: an `:unknown` probe result (an I/O error,
  # not a confirmed absence) is counted but NEVER returned in the missing list,
  # so a transient medium error can never feed a blob to the deleter.
  test "absorb/3 returns only confirmed-missing blobs, never :unknown ones" do
    check = fn id -> Map.get(%{"b" => :missing, "c" => :unknown}, id, :present) end

    {sweep, missing} = Sweep.absorb(Sweep.new(), [{"a", 1}, {"b", 2}, {"c", 3}], check)

    assert {sweep.present, sweep.missing, sweep.unknown} == {1, 1, 1}
    assert missing == [{"b", 2}]
    assert sweep.cursor == "c"
  end
end
