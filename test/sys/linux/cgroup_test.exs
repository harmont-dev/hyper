defmodule Sys.Linux.CgroupTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Cgroup
  alias Sys.Linux.Fstab.Spec

  defp mount(fs_type) do
    %Spec{device: "none", mount_point: "/sys/fs/cgroup", fs_type: fs_type, mount_opts: "rw"}
  end

  test "no cgroup mounts yields an empty set" do
    assert Cgroup.versions_from_mounts([mount("ext4"), mount("proc")]) == MapSet.new()
  end

  test "a v1 mount yields the :cgroup set" do
    assert Cgroup.versions_from_mounts([mount("cgroup")]) == MapSet.new([:cgroup])
  end

  test "a v2 mount yields the :cgroup2 set" do
    assert Cgroup.versions_from_mounts([mount("cgroup2")]) == MapSet.new([:cgroup2])
  end

  test "a hybrid hierarchy yields both versions and ignores other filesystems" do
    mounts = [mount("cgroup"), mount("cgroup2"), mount("ext4")]
    assert Cgroup.versions_from_mounts(mounts) == MapSet.new([:cgroup, :cgroup2])
  end

  test "duplicate cgroup mounts collapse into the set" do
    assert Cgroup.versions_from_mounts([mount("cgroup"), mount("cgroup")]) ==
             MapSet.new([:cgroup])
  end
end
