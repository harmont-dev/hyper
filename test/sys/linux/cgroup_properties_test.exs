defmodule Sys.Linux.CgroupPropertiesTest do
  @moduledoc """
  `Cgroup.versions_from_mounts/1` reduces a mount list to the set of cgroup
  versions present, keyed by `fs_type`. The result is exactly the cgroup
  fs_types that appear: it ignores every other filesystem, is insensitive to
  order and duplication, and never contains a version that was not mounted.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Cgroup
  alias Sys.Linux.Fstab.Spec

  @cgroup_fs ~w(cgroup cgroup2)
  # Filesystem types that must never contribute to the result.
  @other_fs ~w(ext4 xfs btrfs proc sysfs tmpfs overlay)

  defp mount(fs_type) do
    %Spec{device: "none", mount_point: "/x", fs_type: fs_type, mount_opts: "rw"}
  end

  defp fs_type, do: member_of(@cgroup_fs ++ @other_fs)

  property "the result is exactly the set of cgroup fs_types present" do
    check all(types <- list_of(fs_type(), max_length: 20)) do
      mounts = Enum.map(types, &mount/1)

      expected =
        types
        |> Enum.filter(&(&1 in @cgroup_fs))
        |> Enum.map(&String.to_existing_atom/1)
        |> MapSet.new()

      assert Cgroup.versions_from_mounts(mounts) == expected
    end
  end

  property "non-cgroup mounts never change the result" do
    check all(
            types <- list_of(member_of(@cgroup_fs), max_length: 10),
            noise <- list_of(member_of(@other_fs), max_length: 10)
          ) do
      base = Enum.map(types, &mount/1)
      with_noise = Enum.map(types ++ noise, &mount/1)
      assert Cgroup.versions_from_mounts(base) == Cgroup.versions_from_mounts(with_noise)
    end
  end

  property "order and duplication do not affect the result" do
    check all(types <- list_of(fs_type(), max_length: 20)) do
      mounts = Enum.map(types, &mount/1)
      result = Cgroup.versions_from_mounts(mounts)
      assert Cgroup.versions_from_mounts(Enum.reverse(mounts)) == result
      assert Cgroup.versions_from_mounts(mounts ++ mounts) == result
    end
  end

  property "the result is always a subset of {:cgroup, :cgroup2}" do
    check all(types <- list_of(fs_type(), max_length: 20)) do
      result = Cgroup.versions_from_mounts(Enum.map(types, &mount/1))
      assert MapSet.subset?(result, MapSet.new([:cgroup, :cgroup2]))
    end
  end
end
