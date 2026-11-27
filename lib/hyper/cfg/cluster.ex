defmodule Hyper.Cfg.Cluster do
  @moduledoc """
  BEAM cluster (Distributed Erlang) topology for Hyper. Set it in `config.exs`
  via `config :hyper, Hyper.Cfg.Cluster, topologies: [...]` using
  [libcluster](https://github.com/bitwalker/libcluster) topology syntax;
  the application forwards it straight to `Cluster.Supervisor`, which is what
  Horde's `members: :auto` registries form over. `config.exs`-only because a
  topology references strategy modules. The default — `[]` — is a single,
  unclustered node.
  """

  import Hyper.Cfg, only: [fetch_cfg: 1]

  @doc "The libcluster topologies to form the BEAM cluster with."
  @spec topologies :: keyword()
  def topologies do
    case fetch_cfg(toml: "cluster") do
      {:ok, table} -> [hyper: topology(table)]
      :error -> []
    end
  end

  @spec topology(map()) :: keyword()
  defp topology(%{"strategy" => "epmd", "hosts" => hosts}) when is_list(hosts),
    do: [strategy: Cluster.Strategy.Epmd, config: [hosts: Enum.map(hosts, &String.to_atom/1)]]

  defp topology(%{"strategy" => "dns_poll", "query" => query, "node_basename" => basename})
       when is_binary(query) and is_binary(basename),
       do: [strategy: Cluster.Strategy.DNSPoll, config: [query: query, node_basename: basename]]

  defp topology(other) do
    raise ArgumentError,
          "[cluster] must be `strategy = \"epmd\"` with `hosts`, or " <>
            "`strategy = \"dns_poll\"` with `query` and `node_basename`, got: #{inspect(other)}"
  end
end
