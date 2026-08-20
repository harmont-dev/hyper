defmodule Hyper.Cfg.Autoscale do
  @moduledoc """
  Autoscaler configuration, read from the `[autoscale]` TOML table (and, for the
  provider module, `config.exs` app env). Only a `:client` node acts on these: it
  runs `Hyper.Autoscale`, which keeps at least `min_nodes/0` live worker nodes
  (up to `max_nodes/0`) by provisioning them through `provider/0`.

  `provider_cfg/0` gathers everything the provider (default
  `Hyper.Provider.Latitude`) needs into a single atom-keyed map: the API token
  from the `LATITUDE_API_TOKEN` environment variable, the instance shape from
  `autoscale.latitude.*`, and the worker bootstrap parameters from
  `autoscale.bootstrap.*`. A missing token yields `token: nil`, which the
  autoscaler treats as "idle" — it logs once and no-ops rather than crashing.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @doc "Whether the autoscaler should provision worker nodes at all."
  @spec enabled?() :: boolean()
  def enabled?, do: get_cfg(toml: "autoscale.enabled", default: false)

  @doc "The `Hyper.Provider` implementation used to create and destroy nodes."
  @spec provider() :: module()
  def provider do
    get_cfg(runtime: {__MODULE__, :provider}, default: Hyper.Provider.Latitude)
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
  The atom-keyed provider configuration map: credentials, instance shape, and
  the bootstrap params `Hyper.Autoscale.UserData` needs to render cloud-init.
  """
  @spec provider_cfg() :: map()
  def provider_cfg do
    %{
      token: System.get_env("LATITUDE_API_TOKEN"),
      project: latitude("project", nil),
      plan: latitude("plan", nil),
      operating_system: latitude("operating_system", nil),
      site: latitude("site", nil),
      hostname_prefix: latitude("hostname_prefix", "hyper-worker"),
      ssh_keys: latitude("ssh_keys", []),
      billing: latitude("billing", "hourly"),
      release_url: bootstrap("release_url", nil),
      pg_url: bootstrap("pg_url", nil),
      cookie: bootstrap("cookie", nil),
      resolver: bootstrap("resolver", nil)
    }
  end

  @spec latitude(String.t(), term()) :: term()
  defp latitude(key, default), do: get_cfg(toml: "autoscale.latitude.#{key}", default: default)

  @spec bootstrap(String.t(), term()) :: term()
  defp bootstrap(key, default), do: get_cfg(toml: "autoscale.bootstrap.#{key}", default: default)
end
