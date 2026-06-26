defmodule Hyper.Config do
  @moduledoc """
  Host configuration.

  Everything shared with the setuid helper (`native/suidhelper`) is read from the
  single source of truth, `/etc/hyper/config.toml`, at runtime — never duplicated
  in `config :hyper`. The node and the helper parse the same file, so they cannot
  drift: `work_dir`, the `[tools]` binary paths (`firecracker`, `jailer`, ...),
  and the `[jails]` table (`cgroup`, `uid_gid_range`). The file is read once on first access
  and cached in `:persistent_term`; an absent file (local dev / CI) yields the
  same built-in defaults the helper compiles in, so both sides still agree.

  The node's own tools (`skopeo`, `umoci`, `mke2fs`, `suidhelper`) share that same
  `[tools]` table — the helper simply ignores the keys it does not recognise, so
  one table serves both. Only `vmlinux` and the cluster topology remain in
  `config :hyper`.
  """

  # The shared config file, read by both this node and the setuid helper. Absent
  # in local dev / CI, where the built-in defaults below are used instead.
  @config_path "/etc/hyper/config.toml"
  @dev_work_dir "/srv/hyper"

  # Defaults for the helper-shared values, kept in lockstep with the helper's
  # `Config::default` (native/suidhelper/src/config.rs) so an absent config.toml
  # makes the node and the helper agree out of the box.
  @default_parent_cgroup "hyper"
  @default_uid_gid_range {900_000, 999_999}

  # Defaults for the node-only `[tools]` binaries (skopeo/umoci/mke2fs/suidhelper).
  # These bare keys live alongside the helper's own tools in the `[tools]` table;
  # the helper ignores the keys it does not recognise, so the two sides share one
  # table without colliding.
  @default_skopeo "skopeo"
  @default_mke2fs "mke2fs"
  @default_suid_helper "/usr/local/bin/hyper-suidhelper"

  @doc """
  Root work directory for this node. All firecracker paths derive from it.

  Read from `#{@config_path}` (the single source of truth shared with the setuid
  helper) the first time it is needed, then cached via `config_toml/0`. Falls back
  to `#{@dev_work_dir}` when the file is absent (local dev / CI, where the helper
  is not installed anyway).
  """
  @spec work_dir :: Path.t()
  def work_dir, do: Map.get(config_toml(), "work_dir", @dev_work_dir)

  @doc "Directory holding redistributable binaries downloaded by the node."
  @spec redist_dir :: Path.t()
  def redist_dir, do: Path.join(work_dir(), "redist")

  @doc """
  Absolute path to the firecracker binary, from the `[tools]` table in
  `#{@config_path}`. Raises if absent — the operator must configure it; there is
  no default.

  For the launch path only. Pre-launch checks should use `firecracker_bin_configured/0`
  so a missing key returns a typed error rather than crashing.
  """
  @spec firecracker_bin :: Path.t()
  def firecracker_bin, do: fetch_tool!("firecracker")

  @doc """
  Non-raising form of `firecracker_bin/0`. Returns `{:ok, path}` when the
  `[tools] firecracker` key is present in `#{@config_path}`, or `:error` otherwise.
  """
  @spec firecracker_bin_configured :: {:ok, Path.t()} | :error
  def firecracker_bin_configured, do: Map.fetch(tools(), "firecracker")

  @doc """
  Absolute path to the jailer binary, from the `[tools]` table in `#{@config_path}`.
  Raises if absent — the operator must configure it; there is no default.

  For the launch path only. Pre-launch checks should use `jailer_bin_configured/0`
  so a missing key returns a typed error rather than crashing.
  """
  @spec jailer_bin :: Path.t()
  def jailer_bin, do: fetch_tool!("jailer")

  @doc """
  Non-raising form of `jailer_bin/0`. Returns `{:ok, path}` when the
  `[tools] jailer` key is present in `#{@config_path}`, or `:error` otherwise.
  """
  @spec jailer_bin_configured :: {:ok, Path.t()} | :error
  def jailer_bin_configured, do: Map.fetch(tools(), "jailer")

  # The `[tools]` table (binary paths shared with the helper), or `%{}` when the
  # file or table is absent.
  @spec tools :: map()
  defp tools, do: Map.get(config_toml(), "tools", %{})

  @spec fetch_tool!(String.t()) :: Path.t()
  defp fetch_tool!(key) do
    case Map.fetch(tools(), key) do
      {:ok, path} ->
        path

      :error ->
        raise "#{@config_path}: `[tools] #{key}` is not set; " <>
                "operator must configure it before starting the node"
    end
  end

  # A `[tools]` path with a built-in default: the configured string, or `default`
  # when the key is absent (or set to a non-string, treated as unset). The
  # `is_binary/1` guard pins the success type to `String.t()` so the public
  # accessors stay precisely typed for Dialyzer rather than widening to `any()`.
  @spec tool_path(String.t(), String.t()) :: String.t()
  defp tool_path(key, default) do
    case Map.get(tools(), key) do
      path when is_binary(path) -> path
      _ -> default
    end
  end

  # A `[tools]` path with no default: the configured string, or `nil` when unset.
  @spec optional_tool_path(String.t()) :: String.t() | nil
  defp optional_tool_path(key) do
    case Map.get(tools(), key) do
      path when is_binary(path) -> path
      _ -> nil
    end
  end

  @spec config_toml :: map()
  defp config_toml do
    case :persistent_term.get({__MODULE__, :config_toml}, nil) do
      nil ->
        cfg = load_config_toml()
        :persistent_term.put({__MODULE__, :config_toml}, cfg)
        cfg

      cfg ->
        cfg
    end
  end

  @spec load_config_toml :: map()
  defp load_config_toml do
    case File.read(@config_path) do
      {:ok, body} -> Toml.decode!(body)
      {:error, _} -> %{}
    end
  end

  @doc "Directory where `Hyper.Node.FireVMM.VmLinux.Provider` installs guest kernels."
  @spec vmlinux_install_dir :: Path.t()
  def vmlinux_install_dir, do: Path.join(redist_dir(), "vmlinux")

  @doc "Directory where `Hyper.Img.OciLoader.Umoci` installs the default umoci binary."
  @spec umoci_install_dir :: Path.t()
  def umoci_install_dir, do: Path.join(redist_dir(), "umoci")

  @doc """
  Path to the directory where all VM chroot's are created (`<work_dir>/jails`).

  If it does not exist, `Hyper.Node` will attempt to create one.
  """
  @spec chroot_base :: Path.t()
  def chroot_base, do: Path.join(work_dir(), "jails")

  @doc """
  Name of the parent cgroup used as a supervision cgroup for all VMs. Read from
  `[jails] cgroup` in `#{@config_path}` (shared with the helper), default `"hyper"`.
  """
  @spec parent_cgroup :: String.t()
  def parent_cgroup, do: Map.get(jails(), "cgroup", @default_parent_cgroup)

  # The `[jails]` table (VM placement/confinement, shared with the helper), or
  # `%{}` when the file or table is absent.
  @spec jails :: map()
  defp jails, do: Map.get(config_toml(), "jails", %{})

  @doc """
  Path to the directory where all VM sockets are held.

  Must be stable across all nodes, and must be a directory. If it does not exist, `Hyper.Node`
  will attempt to create one.
  """
  @spec socket_dir :: Path.t()
  def socket_dir, do: Path.join(work_dir(), "socks")

  @doc """
  Range in which `Hyper` allocates uid/gids: each VM gets a fresh uid/gid pair in
  this range. Critical that no other process on the system uses this range.

  Read from `[jails] uid_gid_range` (a `[min, max]` array) in `#{@config_path}` —
  the same file the helper validates against, so the node only ever hands out uids
  the helper will accept. Defaults to `#{inspect(@default_uid_gid_range)}` when absent.
  """
  @spec uid_gid_range :: {integer(), integer()}
  def uid_gid_range do
    case Map.get(jails(), "uid_gid_range") do
      [min, max] -> {min, max}
      _ -> @default_uid_gid_range
    end
  end

  @doc """
  Location of all image layers on all nodes.

  Hyper expects you to keep your layers in a flat directory, which may be backed by anything you
  like: a plain filesystem, an NFS drive. This registry only ever is used to find paths to layers
  but not anything more.

  Must be stable across all nodes, and must be a directory. If it does not exist, `Hyper.Node`
  will attempt to create one.

  Derived as `<work_dir>/layers`, so it follows `work_dir` from `#{@config_path}`.
  """
  @spec layer_dir :: Path.t()
  def layer_dir, do: Path.join(work_dir(), "layers")

  @doc """
  Path to the skopeo binary (used by `Hyper.Img.OciLoader` to pull OCI images).
  Read from `[tools] skopeo` in `#{@config_path}`, default `#{@default_skopeo}` (on `PATH`).
  """
  @spec skopeo_path :: String.t()
  def skopeo_path, do: tool_path("skopeo", @default_skopeo)

  @doc """
  Operator-configured path to the umoci binary, or `nil` (the default) to let
  `Hyper.Img.OciLoader.Umoci` download and manage a pinned default. Read from
  `[tools] umoci` in `#{@config_path}`.
  """
  @spec umoci_path :: String.t() | nil
  def umoci_path, do: optional_tool_path("umoci")

  @doc """
  Path to the mke2fs binary (used by `Hyper.Img.OciLoader` to build the ext4 rootfs).
  Read from `[tools] mke2fs` in `#{@config_path}`, default `#{@default_mke2fs}` (on `PATH`).
  """
  @spec mke2fs_path :: String.t()
  def mke2fs_path, do: tool_path("mke2fs", @default_mke2fs)

  @doc """
  Path to the setuid-root device helper (`hyper-suidhelper`). The node runs
  unprivileged and routes every `losetup`/`dmsetup`/`blockdev` operation through
  it.

  Read from `[tools] suidhelper` in `#{@config_path}`, default `#{@default_suid_helper}`
  (the install path used by `mix suidhelper.install`), so an operator who installs
  it elsewhere can override it per node without recompiling.
  """
  @spec suid_helper :: String.t()
  def suid_helper, do: tool_path("suidhelper", @default_suid_helper)

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
  # Runtime read, not `compile_env`: an unset map would inline a literal `%{}`,
  # which the type checker proves makes every `Map.fetch/2` on it return `:error`.
  def vmlinux, do: Application.get_env(:hyper, :vmlinux, %{})
end
