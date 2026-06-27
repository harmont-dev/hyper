defmodule Hyper.Cfg.Cluster do
  @moduledoc """
  BEAM cluster (Distributed Erlang) topology for Hyper. Set it in `config.exs`
  via `config :hyper, Hyper.Cfg.Cluster, topologies: [...]` using
  [libcluster](https://github.com/bitwalker/libcluster) topology syntax;
  `Hyper.Application` forwards it straight to `Cluster.Supervisor`, which is what
  Horde's `members: :auto` registries form over. `config.exs`-only because a
  topology references strategy modules. The default — `[]` — is a single,
  unclustered node.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "The libcluster topologies to form the BEAM cluster with."
  @spec topologies :: keyword()
  def topologies, do: get_cfg(runtime: {__MODULE__, :topologies}, default: [])
end
