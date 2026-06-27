defmodule Hyper.Node.Reaper.PlanPropertiesTest do
  @moduledoc """
  Safety laws every `Hyper.Node.Reaper.Plan` decision must obey, generated over a
  small shared id alphabet so live / cgroup-leaf / rw sets actually overlap:

    * a live vm_id is NEVER a reap candidate (the union of liveness sources is
      removed from the orphan set);
    * only an orphan seen on two consecutive ticks is reaped (`confirm/2` reaps a
      subset of both current and last, and carries `current` forward);
    * `hyper-thinpool` / `hyper-img-*` / any non-`hyper-rw-*` name never yields a
      candidate, and `Mutable.dm_name(id)` round-trips back to exactly `id` (so a
      future id-scheme change that breaks the strip fails loudly here).
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.Img.Mutable
  alias Hyper.Node.Reaper.Plan

  # A deliberately tiny alphabet so generated live/leaf/rw id sets collide often,
  # exercising the difference and intersection rather than always being disjoint.
  defp id, do: member_of(~w(a b c d e))

  defp id_set, do: map(list_of(id()), &MapSet.new/1)

  defp id_list, do: list_of(id())

  property "a live vm_id is never a reap candidate" do
    check all(
            live <- id_set(),
            leaves <- id_list(),
            rw <- id_list()
          ) do
      orphans = Plan.orphans(live, leaves, rw)
      assert MapSet.disjoint?(orphans, live)
    end
  end

  property "only twice-seen orphans are reaped; current is carried forward" do
    check all(
            current <- id_set(),
            last <- id_set()
          ) do
      {reap, next} = Plan.confirm(current, last)

      assert MapSet.subset?(reap, current)
      assert MapSet.subset?(reap, last)
      assert next == current
    end
  end

  property "rw_ids excludes thinpool, img, and non-rw junk" do
    safe_dm =
      member_of([
        "hyper-thinpool",
        "hyper-img-abc-0",
        "hyper-img-deadbeef-3",
        "unrelated-device",
        "cryptroot"
      ])

    check all(names <- list_of(safe_dm)) do
      assert Plan.rw_ids(names) == []
    end
  end

  property "Mutable.dm_name/1 round-trips through rw_ids for a real vm_id" do
    check all(
            id <-
              map(
                binary(min_length: 1, max_length: 16),
                &("v" <> Base.encode32(&1, padding: false, case: :lower))
              )
          ) do
      assert Plan.rw_ids([Mutable.dm_name(id)]) == [id]
    end
  end
end
