defmodule Hyper.Cfg.Network do
  @moduledoc """
  VM egress networking settings from the `[network]` table — `config.toml`-only
  because the setuid helper reads the same `uplink` and `clone_pool` to build
  each VM's netns, veth, and NAT rules. Absent table ⇒ networking disabled: VMs
  boot with no NIC (today's behaviour), the jailer omits `--netns`.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @default_clone_pool "172.31.0.0/16"

  @doc "Whether VM egress networking is turned on (`[network] uplink` present)."
  @spec enabled?() :: boolean()
  def enabled?, do: not is_nil(get_cfg(toml: "network.uplink", default: nil))

  @doc "Physical uplink interface guest egress is NAT'd out of. Raises if enabled but unset."
  @spec uplink() :: String.t()
  def uplink do
    case get_cfg(toml: "network.uplink", default: nil) do
      nil -> raise Hyper.Cfg.MissingError, "network.uplink is required when networking is enabled"
      v when is_binary(v) -> v
      other -> raise ArgumentError, "network.uplink must be a string, got: #{inspect(other)}"
    end
  end

  @doc "IPv4 CIDR the per-VM clone /30s are carved from. `[network] clone_pool`."
  @spec clone_pool() :: String.t()
  def clone_pool, do: get_cfg(toml: "network.clone_pool", default: @default_clone_pool)
end
