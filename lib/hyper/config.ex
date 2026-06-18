defmodule Hyper.Config do
  @jailer_bin Application.compile_env!(:hyper, :jailer_bin)
  @firecracker_bin Application.compile_env!(:hyper, :firecracker_bin)
  @chroot_base Application.compile_env!(:hyper, :jailer_chroot_base)
  @parent_cgroup Application.compile_env(:hyper, :cgroup_parent, "hyper")
  @socket_dir Application.compile_env!(:hyper, :socket_dir)
  @uid_gid_range Application.compile_env!(:hyper, :uid_gid_range)

  @doc "jailer binary path installed on each node. The path must be identical across nodes."
  def jailer_bin, do: @jailer_bin

  @doc "firecracker binary path installed on each node. must be identical across nodes"
  def firecracker_bin, do: @firecracker_bin

  @doc """
  Path to the directory where all VM chroot's are created.

  Must be stable across all nodes, and must be a directory. If it does not exist, `Hyper.Node`
  will attempt to create one.
  """
  def chroot_base, do: @chroot_base

  @doc """
  A name for the parent cgroup which is used as a supervision cgroup for all VMs.
  """
  def parent_cgroup, do: @parent_cgroup

  @doc """
  Path to the directory where all VM sockets are held.

  Must be stable across all nodes, and must be a directory. If it does not exist, `Hyper.Node`
  will attempt to create one.
  """
  @spec socket_dir :: Path.t()
  def socket_dir, do: @socket_dir

  @doc """
  Range in which `Hyper` will attempt to allocate uid/gids. Whenever a VM is allocated, it will
  get a fresh uid/gid pair in this range. It is absolutely critical that this range is not used
  by any other process on the system, as that can risk security.
  """
  @spec uid_gid_range :: {integer(), integer()}
  def uid_gid_range, do: @uid_gid_range
end
