defmodule Hyper.Cfg.Budget do
  @moduledoc """
  This node's resource budget configuration.

  Carries both the hard caps consumed by `Hyper.Node.Budget.Hard` (`mem_max`,
  `disk_max`) and the soft load ceilings consumed by `Hyper.Node.Budget.Soft`.

  The soft side names, per metric, the machine's absolute capacity and the
  fraction of it past which the node is considered too loaded to take on more
  work:

    * `cpu_max_load` - utilization fraction (`0.0..1.0`) above which CPU is full;
      CPU capacity is the whole machine, so no separate cap is needed.
    * `disk_bw_cap` / `disk_bw_max_load` - absolute disk throughput and the
      fraction of it usable before disk is considered saturated.
    * `net_bw_cap` / `net_bw_max_load` - the same for network throughput.
  """

  @type t :: %__MODULE__{
          mem_max: Unit.Information.t(),
          disk_max: Unit.Information.t(),
          cpu_max_load: float(),
          disk_bw_cap: Unit.Bandwidth.t(),
          disk_bw_max_load: float(),
          net_bw_cap: Unit.Bandwidth.t(),
          net_bw_max_load: float()
        }
  defstruct [
    :mem_max,
    :disk_max,
    :cpu_max_load,
    :disk_bw_cap,
    :disk_bw_max_load,
    :net_bw_cap,
    :net_bw_max_load
  ]

  @spec load :: {:ok, t()} | {:error, term()}
  def load do
    case Application.fetch_env(:hyper, __MODULE__) do
      {:ok, env} ->
        case safe_struct(env) do
          {:ok, config} ->
            # TODO(markovejnovic): Check whether the limits are under the
            # system limits by querying Sys.
            :persistent_term.put(__MODULE__, config)
            {:ok, config}

          {:error, _} = err ->
            err
        end

      :error ->
        {:error, :config_missing}
    end
  end

  defp safe_struct(env) do
    {:ok, struct!(__MODULE__, env)}
  rescue
    e in KeyError -> {:error, {:unknown_key, e.key}}
    e in ArgumentError -> {:error, {:invalid_config, e.message}}
  end

  @spec get :: t()
  def get, do: :persistent_term.get(__MODULE__)
end
