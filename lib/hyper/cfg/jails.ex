defmodule Hyper.Cfg.Jails do
  @moduledoc """
  VM confinement settings from the `[jails]` table — `config.toml`-only because
  the setuid helper enforces the same `uid_gid_range` it reads from this file.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @default_range {900_000, 999_999}

  @doc "Parent cgroup for every VM cgroup. `[jails] cgroup`, default `\"hyper\"`."
  @spec cgroup :: String.t()
  def cgroup, do: get_cfg(toml: "jails.cgroup", default: "hyper")

  @doc "UID/GID allocation band each VM jail draws from. `[jails] uid_gid_range`."
  @spec uid_gid_range :: {integer(), integer()}
  def uid_gid_range do
    case Hyper.Cfg.Toml.fetch("jails.uid_gid_range") do
      {:ok, v} -> range_from(v)
      :error -> @default_range
    end
  end

  @doc false
  @spec range_from(term()) :: {integer(), integer()}
  def range_from([min, max]) when is_integer(min) and is_integer(max), do: {min, max}
  def range_from(_), do: @default_range
end
