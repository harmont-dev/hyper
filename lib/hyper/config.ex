defmodule Hyper.Config do
  @moduledoc "Compile-time host configuration, read from `config :hyper, ...` (see `config/config.exs`)."

  @jailer_bin Application.compile_env!(:hyper, :jailer_bin)
  @firecracker_bin Application.compile_env!(:hyper, :firecracker_bin)
  @chroot_base Application.compile_env!(:hyper, :jailer_chroot_base)
  @parent_cgroup Application.compile_env(:hyper, :cgroup_parent, "hyper")
  @socket_dir Application.compile_env!(:hyper, :socket_dir)
  @uid_gid_range Application.compile_env!(:hyper, :uid_gid_range)
  @layer_dir Application.compile_env!(:hyper, :layer_dir)
  @losetup_path Application.compile_env(:hyper, :losetup_path, "losetup")
  @dmsetup_path Application.compile_env(:hyper, :dmsetup_path, "dmsetup")
  @blockdev_path Application.compile_env(:hyper, :blockdev_path, "blockdev")
  @scratch_dir Application.compile_env!(:hyper, :scratch_dir)
  # dm-snapshot exception-store chunk size, in 512-byte sectors (8 = 4 KiB).
  # Standardised repo-wide; deltas must be created with this chunk size.
  @chunk_sectors Application.compile_env(:hyper, :chunk_sectors, 8)

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

  @doc """
  Location of all image layers on all nodes.

  Hyper expects you to keep your layers in a flat directory, which may be backed by anything you
  like: a plain filesystem, an NFS drive. This registry only ever is used to find paths to layers
  but not anything more.

  Must be stable across all nodes, and must be a directory. If it does not exist, `Hyper.Node`
  will attempt to create one.
  """
  @spec layer_dir :: Path.t()
  def layer_dir, do: @layer_dir

  @doc "Path to the losetup binary."
  def losetup_path, do: @losetup_path

  @doc "Path to the dmsetup binary."
  def dmsetup_path, do: @dmsetup_path

  @doc "Path to the blockdev binary."
  def blockdev_path, do: @blockdev_path

  @doc """
  Path to the setuid-root device helper (`hyper-suidhelper`). Required: the node
  runs unprivileged and routes every `losetup`/`dmsetup`/`blockdev` operation
  through it.

  Runtime config (host-specific), so it can be set per node without recompiling.
  """
  @spec suid_helper :: Path.t()
  def suid_helper, do: Application.fetch_env!(:hyper, :suid_helper)

  @doc """
  Directory for per-VM scratch (writable-layer COW) files. Must be node-local and
  writable. If it does not exist, `Hyper.Node` will attempt to create one.
  """
  @spec scratch_dir :: Path.t()
  def scratch_dir, do: @scratch_dir

  @doc "dm-snapshot exception-store chunk size, in 512-byte sectors (8 = 4 KiB)."
  @spec chunk_sectors :: pos_integer()
  def chunk_sectors, do: @chunk_sectors
end
