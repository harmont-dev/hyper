defmodule Hyper.Node.Budget.NodeState do
  @moduledoc """
  The per-node resource snapshot published into `Hyper.Cluster.Budget` and read by
  `Hyper.Scheduler` as the first pass of placement.

  Approximate by design: hard headroom is exact at publish time but soft load is
  an EWMA that drifts and the record gossips with lag. The authoritative decision
  is always the owning node's `Hyper.Node.Budget.admit/2`. Each record carries the
  node's load *and* its ceilings, so a scheduler anywhere can evaluate fit without
  knowing the target's config or core count.
  """

  alias Hyper.Node.Budget.Hard
  alias Hyper.Node.Config.Budget, as: Config
  alias Sys.Mon
  alias Sys.Mon.Server.Reading
  alias Unit.Bandwidth

  @type t :: %__MODULE__{
          node: node(),
          mem_free: Unit.Information.t(),
          disk_free: Unit.Information.t(),
          cpu_load: float(),
          cpu_capacity: pos_integer(),
          cpu_max_load: float(),
          disk_bw_load: Unit.Bandwidth.t(),
          disk_bw_ceiling: Unit.Bandwidth.t(),
          net_bw_load: Unit.Bandwidth.t(),
          net_bw_ceiling: Unit.Bandwidth.t(),
          layers: [Hyper.Layer.id()]
        }

  @enforce_keys [
    :node,
    :mem_free,
    :disk_free,
    :cpu_load,
    :cpu_capacity,
    :cpu_max_load,
    :disk_bw_load,
    :disk_bw_ceiling,
    :net_bw_load,
    :net_bw_ceiling,
    :layers
  ]
  defstruct @enforce_keys

  @doc "Snapshot this node's current budget state."
  @spec build() :: t()
  def build do
    config = Config.get()
    headroom = Hard.headroom()
    readings = Mon.readings()

    %__MODULE__{
      node: node(),
      mem_free: headroom.mem,
      disk_free: headroom.disk,
      cpu_load: smoothed_float(readings.cpu),
      cpu_capacity: System.schedulers_online(),
      cpu_max_load: config.cpu_max_load,
      disk_bw_load: smoothed_bandwidth(readings.disk_bw),
      disk_bw_ceiling: ceiling(config.disk_bw_cap, config.disk_bw_max_load),
      net_bw_load: smoothed_bandwidth(readings.net_bw),
      net_bw_ceiling: ceiling(config.net_bw_cap, config.net_bw_max_load),
      layers: Hyper.Node.Layer.active()
    }
  end

  # Instantaneous ceiling for a bandwidth metric: fraction `k` of capacity (same
  # formula as Hyper.Node.Budget.Soft; kept local so the record is self-contained).
  @spec ceiling(Bandwidth.t(), float()) :: Bandwidth.t()
  defp ceiling(cap, k), do: Bandwidth.bps(round(k * Bandwidth.as_bytes_per_sec(cap)))

  # An unmeasured metric (nil before the first sample) reads as idle.
  @spec smoothed_float(Reading.t()) :: float()
  defp smoothed_float(%Reading{smoothed: nil}), do: 0.0
  defp smoothed_float(%Reading{smoothed: v}), do: v

  @spec smoothed_bandwidth(Reading.t()) :: Bandwidth.t()
  defp smoothed_bandwidth(%Reading{smoothed: nil}), do: Bandwidth.zero()
  defp smoothed_bandwidth(%Reading{smoothed: v}), do: v
end
