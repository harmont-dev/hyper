defmodule Hyper.Cfg.Network do
  @moduledoc """
  Unimplemented placeholder pending the VM-networking rewrite.

  A `[network]` table in `/etc/hyper/config.toml` is tolerated but ignored
  (`Hyper.Cfg.Toml` is a loose dotted-path lookup), and a node no longer
  requires it to start. Every function raises; nothing in Hyper calls them.
  """

  @doc "Unimplemented: whether VM networking is configured."
  @spec configured?() :: no_return()
  def configured?,
    do:
      raise("Hyper.Cfg.Network.configured?/0 is unimplemented: VM networking is being rewritten")

  @doc "Unimplemented: the uplink interface guest egress leaves through."
  @spec uplink() :: no_return()
  def uplink,
    do: raise("Hyper.Cfg.Network.uplink/0 is unimplemented: VM networking is being rewritten")

  @doc "Unimplemented: the address pool per-VM links are carved from."
  @spec clone_pool() :: no_return()
  def clone_pool,
    do: raise("Hyper.Cfg.Network.clone_pool/0 is unimplemented: VM networking is being rewritten")

  @doc "Unimplemented: the DNS resolver handed to guests."
  @spec resolver() :: no_return()
  def resolver,
    do: raise("Hyper.Cfg.Network.resolver/0 is unimplemented: VM networking is being rewritten")
end
