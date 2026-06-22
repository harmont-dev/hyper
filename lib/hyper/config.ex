defmodule Hyper.Config do
  @moduledoc """
  Host configuration, read from `config :hyper, ...` (see `config/config.exs`).

  `work_dir` is the one value shared with the setuid helper
  (`native/suidhelper`); both sides read it from `/etc/hyper/config.toml` at
  runtime (loaded into the app env by `config/runtime.exs`) so the data root has
  a single source of truth. Everything else is compile-time.
  """

  @parent_cgroup Application.compile_env(:hyper, :cgroup_parent, "hyper")
  @uid_gid_range Application.compile_env!(:hyper, :uid_gid_range)
  @layer_dir Application.compile_env!(:hyper, :layer_dir)
  @losetup_path Application.compile_env(:hyper, :losetup_path, "losetup")
  @dmsetup_path Application.compile_env(:hyper, :dmsetup_path, "dmsetup")
  @blockdev_path Application.compile_env(:hyper, :blockdev_path, "blockdev")
  @vmlinux Application.compile_env(:hyper, :vmlinux, %{})

  @doc """
  Root work directory for this node. All firecracker paths derive from it.

  Shared with the setuid helper via `/etc/hyper/config.toml`; populated into the
  app env at runtime by `config/runtime.exs`.
  """
  @spec work_dir :: Path.t()
  def work_dir, do: Application.fetch_env!(:hyper, :work_dir)

  @doc "Directory holding redistributable binaries downloaded by the node."
  @spec redist_dir :: Path.t()
  def redist_dir, do: Path.join(work_dir(), "redist")

  @doc "Directory where `Hyper.Node.FireVMM.Provider` installs the firecracker release."
  @spec firecracker_install_dir :: Path.t()
  def firecracker_install_dir, do: Path.join(redist_dir(), "firecracker")

  @doc """
  Path to the directory where all VM chroot's are created (`<work_dir>/jails`).

  If it does not exist, `Hyper.Node` will attempt to create one.
  """
  @spec chroot_base :: Path.t()
  def chroot_base, do: Path.join(work_dir(), "jails")

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
  def socket_dir, do: Path.join(work_dir(), "socks")

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
  def scratch_dir, do: Path.join(work_dir(), "scratch")

  @doc """
  Per-architecture vmlinux (guest kernel) image paths, keyed by `Sys.Arch.t()`.
  The operator places the kernels on the host and points these at them;
  `Hyper.Node.Vmlinux` resolves and validates them per node.
  """
  @spec vmlinux :: %{optional(Sys.Arch.t()) => Path.t()}
  def vmlinux, do: @vmlinux
end
