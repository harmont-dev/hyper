defmodule Hyper.SuidHelper.DmsetupTest do
  use ExUnit.Case, async: true

  test "parse_targets/1 extracts target names from dmsetup output" do
    out = "snapshot v1\nthin-pool v2\nthin v3\n"
    set = Hyper.SuidHelper.Dmsetup.parse_targets(out)
    assert MapSet.member?(set, "snapshot")
    assert MapSet.member?(set, "thin-pool")
    assert MapSet.member?(set, "thin")
  end
end
