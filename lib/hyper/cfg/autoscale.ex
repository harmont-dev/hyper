defmodule Hyper.Cfg.Autoscale do
  @moduledoc """
  Autoscaler configuration, read from the `[autoscale]` TOML table (and, for the
  provider module, `config.exs` app env). Only a `:client` node acts on these: it
  runs `Hyper.Autoscale`, which keeps at least `min_nodes/0` live worker nodes
  (up to `max_nodes/0`) by provisioning them through `provider/0`.

  `provider_cfg/0` is provider-driven: it merges the whole
  `[autoscale.<provider cfg_namespace>]` sub-table with the shared
  `[autoscale.bootstrap]` params, so a provider can add settings without this
  module knowing about them. Whether the resulting map is sufficient to
  provision is the provider's own `c:Hyper.Provider.validate_cfg/1` decision.
  """

  import Hyper.Cfg, only: [get_cfg: 1, fetch_cfg: 1]

  @providers %{
    "latitude" => Hyper.Provider.Latitude,
    "gcp" => Hyper.Provider.Gcp
  }

  @doc "Whether the autoscaler should provision worker nodes at all."
  @spec enabled?() :: boolean()
  def enabled?, do: get_cfg(toml: "autoscale.enabled", default: false)

  @doc """
  The `Hyper.Provider` implementation used to create and destroy nodes. Resolved
  from the app-env override first, then the `autoscale.provider` TOML key
  (`"latitude"` or `"gcp"`), defaulting to `Hyper.Provider.Latitude`.
  """
  @spec provider() :: module()
  def provider do
    case fetch_cfg(runtime: {__MODULE__, :provider}) do
      {:ok, module} when is_atom(module) -> module
      _ -> provider_module(get_cfg(toml: "autoscale.provider", default: "latitude"))
    end
  end

  @spec provider_module(term()) :: module()
  defp provider_module(name) when is_binary(name) do
    case Map.fetch(@providers, String.downcase(name)) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "unknown autoscale.provider #{inspect(name)}; expected one of " <>
                inspect(Map.keys(@providers))
    end
  end

  defp provider_module(other) do
    raise ArgumentError, "autoscale.provider must be a string, got: #{inspect(other)}"
  end

  @doc "Minimum number of live worker nodes to keep provisioned."
  @spec min_nodes() :: non_neg_integer()
  def min_nodes, do: get_cfg(toml: "autoscale.min_nodes", default: 0)

  @doc "Hard ceiling on the number of worker nodes the autoscaler may create."
  @spec max_nodes() :: non_neg_integer()
  def max_nodes, do: get_cfg(toml: "autoscale.max_nodes", default: 4)

  @doc "How long a worker must be idle before it is eligible to drain. Unused in v1."
  @spec idle_cooldown_ms() :: pos_integer()
  def idle_cooldown_ms, do: get_cfg(toml: "autoscale.idle_cooldown_ms", default: 600_000)

  @doc "Interval between autoscaler reconcile ticks, in milliseconds."
  @spec reconcile_interval_ms() :: pos_integer()
  def reconcile_interval_ms, do: get_cfg(toml: "autoscale.reconcile_interval_ms", default: 30_000)

  @doc """
  How long a machine that the provider reported as created counts as committed
  capacity while its bootstrap script runs and before it heartbeats as live.
  """
  @spec provision_timeout_ms() :: pos_integer()
  def provision_timeout_ms, do: get_cfg(toml: "autoscale.provision_timeout_ms", default: 900_000)

  @doc """
  The atom-keyed provider configuration map: every key under
  `[autoscale.<namespace>]` plus the `[autoscale.bootstrap]` params
  (`release_url`, `pg_url`, `cookie`, `resolver`) and the Latitude API token,
  which only `Hyper.Provider.Latitude.validate_cfg/1` looks at.
  """
  @spec provider_cfg() :: map()
  def provider_cfg do
    namespace = provider().cfg_namespace()

    base = %{
      token: System.get_env("LATITUDE_API_TOKEN"),
      hostname_prefix: "hyper-worker",
      ssh_keys: [],
      billing: "hourly",
      release_url: bootstrap("release_url"),
      pg_url: bootstrap("pg_url"),
      cookie: bootstrap("cookie"),
      resolver: bootstrap("resolver")
    }

    Map.merge(base, namespace_cfg(namespace))
  end

  @spec namespace_cfg(String.t()) :: map()
  defp namespace_cfg(namespace) do
    case fetch_cfg(toml: "autoscale.#{namespace}") do
      {:ok, table} when is_map(table) ->
        Map.new(table, fn {key, value} -> {String.to_atom(key), value} end)

      _ ->
        %{}
    end
  end

  @spec bootstrap(String.t()) :: term()
  defp bootstrap(key), do: get_cfg(toml: "autoscale.bootstrap.#{key}", default: nil)
end
