defmodule Hyper.Cfg.ClusterTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
  end

  test "each [cluster] table maps to its libcluster topology" do
    rows = [
      {%{}, []},
      {%{"cluster" => %{"strategy" => "epmd", "hosts" => ["a@10.0.0.1", "b@10.0.0.2"]}},
       [
         hyper: [
           strategy: Cluster.Strategy.Epmd,
           config: [hosts: [:"a@10.0.0.1", :"b@10.0.0.2"]]
         ]
       ]},
      {%{
         "cluster" => %{
           "strategy" => "dns_poll",
           "query" => "hyper.internal",
           "node_basename" => "hyper"
         }
       },
       [
         hyper: [
           strategy: Cluster.Strategy.DNSPoll,
           config: [query: "hyper.internal", node_basename: "hyper"]
         ]
       ]}
    ]

    for {toml, expected} <- rows do
      Toml.put_cache(toml)
      assert Hyper.Cfg.Cluster.topologies() == expected, inspect(toml)
    end
  end

  test "an unknown strategy or a strategy missing its keys refuses to load" do
    rows = [
      %{"strategy" => "gossip"},
      %{"strategy" => "epmd"},
      %{"strategy" => "dns_poll", "query" => "hyper.internal"},
      %{"hosts" => ["a@10.0.0.1"]}
    ]

    for table <- rows do
      Toml.put_cache(%{"cluster" => table})
      assert_raise ArgumentError, ~r/\[cluster\]/, fn -> Hyper.Cfg.Cluster.topologies() end
    end
  end
end
