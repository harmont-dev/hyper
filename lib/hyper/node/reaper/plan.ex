defmodule Hyper.Node.Reaper.Plan do
  @moduledoc """
  Pure reap-decision core for `Hyper.Node.Reaper`. No I/O. Every safety invariant
  is a property of these functions: a live vm_id is never a candidate, only an
  orphan seen on two consecutive ticks is reaped, and only `hyper-rw-*` dm names
  yield candidates (so `hyper-thinpool` / `hyper-img-*` can never be reaped).
  """

  @rw_prefix "hyper-rw-"

  @doc "vm_ids of orphan rw-volumes from raw `dmsetup ls` names (only `hyper-rw-*`)."
  @spec rw_ids([String.t()]) :: [String.t()]
  def rw_ids(dm_names) do
    for name <- dm_names,
        String.starts_with?(name, @rw_prefix),
        do: String.replace_prefix(name, @rw_prefix, "")
  end

  @doc "Candidate orphans this tick: (cgroup leaves ∪ rw vm_ids) minus the live set."
  @spec orphans(MapSet.t(String.t()), [String.t()], [String.t()]) :: MapSet.t(String.t())
  def orphans(live, cgroup_leaves, rw_ids) do
    cgroup_leaves
    |> MapSet.new()
    |> MapSet.union(MapSet.new(rw_ids))
    |> MapSet.difference(live)
  end

  @doc "Two-strike grace: reap only ids that were also orphans last tick. Returns {to_reap, next_last}."
  @spec confirm(MapSet.t(String.t()), MapSet.t(String.t())) ::
          {MapSet.t(String.t()), MapSet.t(String.t())}
  def confirm(current, last), do: {MapSet.intersection(current, last), current}
end
