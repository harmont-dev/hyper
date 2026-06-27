defmodule Hyper.Cfg.Jails do
  @moduledoc """
  VM confinement settings from the `[jails]` table — `config.toml`-only because
  the setuid helper enforces the same `uid_gid_range` it reads from this file.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "Parent cgroup for every VM cgroup. `[jails] cgroup`, default `\"hyper\"`."
  @spec cgroup :: String.t()
  def cgroup, do: get_cfg(toml: "jails.cgroup", default: "hyper")

  @doc """
  UID/GID allocation band each VM jail draws from (`[jails] uid_gid_range`, a
  required `[min, max]` integer array). Raises `Hyper.Cfg.MissingError` when it
  is unset, and `ArgumentError` when it is not a pair of integers — a bogus band
  must never silently confine a VM.
  """
  @spec uid_gid_range :: {integer(), integer()}
  def uid_gid_range, do: range_from(get_cfg(toml: "jails.uid_gid_range"))

  @spec range_from(term()) :: {integer(), integer()}
  defp range_from([min, max]) when is_integer(min) and is_integer(max), do: {min, max}

  defp range_from(other) do
    raise ArgumentError, "jails.uid_gid_range must be [min, max] integers, got: #{inspect(other)}"
  end
end
