defmodule Hyper.Cfg.Dirs do
  @moduledoc """
  The node's work directory and every directory derived from it.

  `work_dir` is the single configurable root (`config.toml`-only, shared with the
  setuid helper); everything else is a fixed sub-path so the node and helper
  agree on layout without a second key to keep in sync.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "Root work directory for this node. config.toml `work_dir`, default `/srv/hyper`."
  @spec work_dir :: Path.t()
  def work_dir, do: get_cfg(toml: "work_dir", default: "/srv/hyper")

  @doc "Read-only image layer store. Delegates to `Hyper.Cfg.Img.store/0`."
  @spec layer_dir :: Path.t()
  def layer_dir, do: Hyper.Cfg.Img.store()

  @doc "Per-VM control/gRPC sockets (`<work_dir>/socks`)."
  @spec socket_dir :: Path.t()
  def socket_dir, do: Path.join(work_dir(), "socks")

  @doc "Per-VM copy-on-write writable layers (`<work_dir>/scratch`)."
  @spec scratch_dir :: Path.t()
  def scratch_dir, do: Path.join(work_dir(), "scratch")

  @doc "Per-VM chroot directories (`<work_dir>/jails`)."
  @spec chroot_base :: Path.t()
  def chroot_base, do: Path.join(work_dir(), "jails")

  @doc "Node-downloaded binaries (`<work_dir>/redist`)."
  @spec redist_dir :: Path.t()
  def redist_dir, do: Path.join(work_dir(), "redist")

  @doc "Where guest kernels install (`<work_dir>/redist/vmlinux`)."
  @spec vmlinux_install_dir :: Path.t()
  def vmlinux_install_dir, do: Path.join(redist_dir(), "vmlinux")

  @doc "Where the default umoci installs (`<work_dir>/redist/umoci`)."
  @spec umoci_install_dir :: Path.t()
  def umoci_install_dir, do: Path.join(redist_dir(), "umoci")

  @doc "Where a node-downloaded firecracker installs (`<work_dir>/redist/firecracker`)."
  @spec firecracker_install_dir :: Path.t()
  def firecracker_install_dir, do: Path.join(redist_dir(), "firecracker")
end
