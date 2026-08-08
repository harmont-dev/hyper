defmodule Hyper.Cfg.Network do
  @moduledoc """
  VM egress networking settings from the `[network]` table — `config.toml`-only
  because the setuid helper reads the same `uplink` and `clone_pool` to build
  each VM's netns, veth, and NAT rules.

  Networking is **mandatory**: a node refuses to start unless `[network]` is
  configured (see `Hyper.Node.FireVMM.Jailer.Checks.network_ready/0`). Every VM
  gets a NIC; there is no opt-out. `configured?/0` exists only so the startup
  preflight can fail fast with a clear message rather than crash later.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @default_clone_pool "172.31.0.0/16"
  @default_resolver "1.1.1.1"

  @doc """
  Whether the required `[network] uplink` is present. Used only by the startup
  preflight to fail fast; once a node is running, networking is guaranteed
  configured, so runtime code calls `uplink/0` directly.
  """
  @spec configured?() :: boolean()
  def configured?, do: not is_nil(get_cfg(toml: "network.uplink", default: nil))

  @doc "Physical uplink interface guest egress is NAT'd out of. Raises if unset (a running node has already passed the preflight)."
  @spec uplink() :: String.t()
  def uplink do
    case get_cfg(toml: "network.uplink", default: nil) do
      nil ->
        raise Hyper.Cfg.MissingError, "network.uplink is required — VM networking is mandatory"

      v when is_binary(v) ->
        v

      other ->
        raise ArgumentError, "network.uplink must be a string, got: #{inspect(other)}"
    end
  end

  @doc "IPv4 CIDR the per-VM clone /30s are carved from. `[network] clone_pool`."
  @spec clone_pool() :: String.t()
  def clone_pool, do: get_cfg(toml: "network.clone_pool", default: @default_clone_pool)

  @doc """
  Host TCP ports guests are allowed to reach, as `[network] host_ports`.

  Guests are otherwise cut off from the host entirely — the input chain drops
  everything sourced from the clone pool, so a host-local service is
  unreachable even though the guest can route to it. Naming a port here punches
  a single hole for it. Empty by default; each entry is a deliberate,
  auditable exemption.
  """
  @spec host_ports() :: [non_neg_integer()]
  def host_ports, do: get_cfg(toml: "network.host_ports", default: [])

  @doc """
  DNS resolver IP handed to the guest via the `hyper.resolver=` kernel cmdline
  param, since the kernel's `ip=` autoconfig sets the guest's address/route but
  never DNS. The PID-1 guest agent reads this back out of `/proc/cmdline` and
  writes it to `/etc/resolv.conf`. `[network] resolver`.
  """
  @spec resolver() :: String.t()
  def resolver, do: get_cfg(toml: "network.resolver", default: @default_resolver)
end
