defmodule Hyper.SuidHelper.LosetupTest do
  @moduledoc """
  `parse_list/1` turns `losetup --list --output NAME,BACK-FILE` rows into
  `{device, backing_file}` pairs. The reclaim pass relies on it to recognise loop
  devices backing Hyper's files, so the edges that matter are: a loop with no
  backing file (skipped, nothing to reclaim by file) and a `(deleted)` backing
  suffix (kept, so the data-dir prefix still matches).
  """
  use ExUnit.Case, async: true

  alias Hyper.SuidHelper.Losetup

  test "pairs device with backing file and skips rows that have no backing file" do
    out = """
    /dev/loop0 /srv/hyper/scratch/thinpool.meta
    /dev/loop1 /srv/hyper/layers/blob
    /dev/loop2
    """

    assert Losetup.parse_list(out) == [
             {"/dev/loop0", "/srv/hyper/scratch/thinpool.meta"},
             {"/dev/loop1", "/srv/hyper/layers/blob"}
           ]
  end

  test "keeps a `(deleted)` backing suffix so data-dir prefix matching still works" do
    out = "/dev/loop0 /srv/hyper/scratch/thinpool.data (deleted)\n"

    assert Losetup.parse_list(out) == [
             {"/dev/loop0", "/srv/hyper/scratch/thinpool.data (deleted)"}
           ]
  end

  test "an empty listing yields no pairs" do
    assert Losetup.parse_list("") == []
  end
end
