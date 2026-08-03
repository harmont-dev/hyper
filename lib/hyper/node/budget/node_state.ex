defmodule Hyper.Node.Budget.NodeState do
  @moduledoc """
  The per-node resource snapshot published into `Hyper.Cluster.Budget` and read by
  `Hyper.Cluster.Scheduler` as the first pass of placement.

  Approximate by design: hard headroom is exact at publish time but soft load is
  an EWMA that drifts and the record gossips with lag. The authoritative decision
  is always the owning node's `Hyper.Node.Budget.admit/2`. Each record carries the
  node's load *and* its ceilings, so a scheduler anywhere can evaluate fit without
  knowing the target's config or core count.

  Separately from any resource number, `drain` carries the node's cordon
  (`Hyper.Node.Cordon`): an operator or the fleet regulator has declared that no
  *new* VM should be placed here, whatever the headroom says. It is a statement of
  intent about the machine's future, not a measurement of its present, and it is
  the only field of this record that is not derived from the hardware.
  """

  alias Hyper.Cfg.Budget, as: Config
  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance.Spec
  alias Sys.Mon
  alias Sys.Mon.Server.Reading
  alias Unit.Bandwidth
  alias Unit.Information

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
          layers: [Hyper.Layer.id()],
          drain: boolean()
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
  # `drain` is the one field left out of @enforce_keys, defaulting to false: it is
  # also the one field a peer running an older release will not send at all. Both
  # the absent and the defaulted flag must read as "not cordoned", because that is
  # the only answer available for a node that predates cordoning - so `fits?/2`
  # matches on it positionally rather than reading it, and an old record costs an
  # extra scheduling round instead of crashing the scheduler.
  defstruct @enforce_keys ++ [drain: false]

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
      layers: Hyper.Node.Layer.active(),
      drain: Hyper.Node.Cordon.drained?()
    }
  end

  @doc """
  Whether this snapshot's node can hold `spec`: hard memory/disk headroom plus the
  soft cpu/disk-bw/net-bw load ceilings. A pure predicate over the published
  snapshot; the authoritative check is still the owning node's
  `Hyper.Node.Budget.admit/2`.

  A cordoned node holds nothing. `drain` is checked first and answers for the
  whole predicate, so a machine being emptied contributes zero capacity to every
  caller - placement and fleet headroom alike - without either having to know the
  flag exists.
  """
  @spec fits?(t(), Spec.t()) :: boolean()
  def fits?(%__MODULE__{drain: true}, _spec), do: false
  def fits?(state, spec), do: hard_fits?(state, spec) and soft_fits?(state, spec)

  @spec hard_fits?(t(), Spec.t()) :: boolean()
  defp hard_fits?(state, spec) do
    Information.as_bytes(spec.mem) <= Information.as_bytes(state.mem_free) and
      Information.as_bytes(spec.disk) <= Information.as_bytes(state.disk_free)
  end

  @spec soft_fits?(t(), Spec.t()) :: boolean()
  defp soft_fits?(state, spec) do
    cpu_ok = state.cpu_load + spec.vcpus / state.cpu_capacity <= state.cpu_max_load

    disk_ok =
      Bandwidth.as_bytes_per_sec(state.disk_bw_load) + Bandwidth.as_bytes_per_sec(spec.disk_bw) <=
        Bandwidth.as_bytes_per_sec(state.disk_bw_ceiling)

    net_ok =
      Bandwidth.as_bytes_per_sec(state.net_bw_load) + Bandwidth.as_bytes_per_sec(spec.net_bw) <=
        Bandwidth.as_bytes_per_sec(state.net_bw_ceiling)

    cpu_ok and disk_ok and net_ok
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
