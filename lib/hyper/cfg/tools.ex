defmodule Hyper.Cfg.Tools do
  @moduledoc """
  Paths to every external binary Hyper runs, read from the `[tools]` table.

  The privileged tools (`firecracker`, `jailer`, `dmsetup`, `losetup`,
  `blockdev`) are read **only** from `/etc/hyper/config.toml` — the file the
  setuid helper also parses, so node and helper can never disagree on a
  root-impacting path. The node-only tools (`skopeo`, `mke2fs`, `umoci`,
  `suidhelper`) run unprivileged, so `/etc/hyper/config.exs` may override them
  (e.g. a path from a secrets manager), then `config.toml`, then the default.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "Firecracker binary. Required — raises if `[tools] firecracker` is unset."
  @spec firecracker :: Path.t()
  def firecracker, do: get_cfg(toml: "tools.firecracker")

  @doc "Non-raising `firecracker/0`."
  @spec firecracker_configured :: {:ok, Path.t()} | :error
  def firecracker_configured, do: Hyper.Cfg.Toml.fetch("tools.firecracker")

  @doc "Jailer binary. Required — raises if `[tools] jailer` is unset."
  @spec jailer :: Path.t()
  def jailer, do: get_cfg(toml: "tools.jailer")

  @doc "Non-raising `jailer/0`."
  @spec jailer_configured :: {:ok, Path.t()} | :error
  def jailer_configured, do: Hyper.Cfg.Toml.fetch("tools.jailer")

  @doc "skopeo binary (node tool). config.exs > config.toml > `skopeo` on PATH."
  @spec skopeo :: String.t()
  def skopeo, do: get_cfg(runtime: {__MODULE__, :skopeo}, toml: "tools.skopeo", default: "skopeo")

  @doc "mke2fs binary (node tool). config.exs > config.toml > `mke2fs` on PATH."
  @spec mke2fs :: String.t()
  def mke2fs, do: get_cfg(runtime: {__MODULE__, :mke2fs}, toml: "tools.mke2fs", default: "mke2fs")

  @doc "umoci binary (node tool), or `nil` to let Hyper download a pinned release."
  @spec umoci :: String.t() | nil
  def umoci, do: get_cfg(runtime: {__MODULE__, :umoci}, toml: "tools.umoci", default: nil)

  @doc "setuid device helper (node tool). config.exs > config.toml > install default."
  @spec suidhelper :: String.t()
  def suidhelper,
    do:
      get_cfg(
        runtime: {__MODULE__, :suidhelper},
        toml: "tools.suidhelper",
        default: "/usr/local/bin/hyper-suidhelper"
      )
end
