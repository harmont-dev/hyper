defmodule Sys.Linux.DmsetupTest do
  use ExUnit.Case, async: true

  test "parse_targets/1 extracts target names" do
    out = "snapshot         v1.16.0\nthin-pool        v1.23.0\nthin             v1.23.0\n"
    set = Sys.Linux.Dmsetup.parse_targets(out)
    assert MapSet.member?(set, "snapshot")
    assert MapSet.member?(set, "thin-pool")
    assert MapSet.member?(set, "thin")
  end
end
