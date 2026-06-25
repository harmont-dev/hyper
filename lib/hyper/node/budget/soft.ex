defmodule Hyper.Node.Budget.Soft do
  @moduledoc """
  Soft per-node admission check. Where `Hyper.Node.Budget.Hard` tracks memory and
  disk reserved from VM specs, `Soft` holds no state: it answers, from this node's
  *live* resource monitors (`Sys.Mon`), whether the machine currently has the
  instantaneous headroom to take on another VM.

  The soft metrics are the ones whose overcommitment degrades speed rather than
  correctness: CPU utilization, disk bandwidth, and network bandwidth. For each,
  the node carries a load ceiling in `Hyper.Node.Config.Budget` (e.g. "never
  schedule onto a machine already past 80% CPU"). A spec is admissible only if the
  measured load plus the spec's nominal demand stays under that ceiling on every
  metric.

  This is purely the instantaneous load filter; it does not model per-VM
  reservations or node overcommit, which are `Hard`'s concern.
  """

  use Unit.Operators
  use OpenTelemetryDecorator

  alias Hyper.Node.Config.Budget, as: Config
  alias Hyper.Vm.Instance
  alias Sys.Mon
  alias Sys.Mon.Server.Reading
  alias Unit.Bandwidth

  @doc """
  Does this node's current measured load leave room to run `spec`?

  `:ok` if every soft metric stays under its load ceiling once `spec`'s demand is
  added, otherwise `{:error, reason}` naming the first saturated metric.
  """
  @spec can_run(Instance.Spec.t()) :: :ok | {:error, term()}
  @decorate with_span("Hyper.Node.Budget.Soft.can_run", include: [:spec])
  def can_run(spec) do
    readings = Mon.readings()
    config = Config.get()

    with :ok <- check_cpu(spec, readings, config),
         :ok <- check_disk_bw(spec, readings, config) do
      check_net_bw(spec, readings, config)
    end
  end

  # CPU is a utilization fraction (0.0..1.0) normalized across every logical core,
  # so a spec's vcpu count converts to the fraction of the machine it asks for.
  @spec check_cpu(Instance.Spec.t(), Mon.Readings.t(), Config.t()) :: :ok | {:error, term()}
  defp check_cpu(spec, readings, config) do
    load = smoothed_float(readings.cpu)
    demand = spec.vcpus / max(System.schedulers_online(), 1)

    if load + demand > config.cpu_max_load do
      {:error, :cpu_saturated}
    else
      :ok
    end
  end

  @spec check_disk_bw(Instance.Spec.t(), Mon.Readings.t(), Config.t()) :: :ok | {:error, term()}
  defp check_disk_bw(spec, readings, config) do
    bandwidth_fits(
      smoothed_bandwidth(readings.disk_bw),
      spec.disk_bw,
      ceiling(config.disk_bw_cap, config.disk_bw_max_load),
      :disk_bw_saturated
    )
  end

  @spec check_net_bw(Instance.Spec.t(), Mon.Readings.t(), Config.t()) :: :ok | {:error, term()}
  defp check_net_bw(spec, readings, config) do
    bandwidth_fits(
      smoothed_bandwidth(readings.net_bw),
      spec.net_bw,
      ceiling(config.net_bw_cap, config.net_bw_max_load),
      :net_bw_saturated
    )
  end

  @spec bandwidth_fits(Bandwidth.t(), Bandwidth.t(), Bandwidth.t(), term()) ::
          :ok | {:error, term()}
  defp bandwidth_fits(load, demand, ceiling, reason) do
    if load + demand > ceiling, do: {:error, reason}, else: :ok
  end

  # The instantaneous ceiling for a bandwidth metric: the fraction `k` of the
  # machine's absolute capacity that may be in use before it counts as saturated.
  @spec ceiling(Bandwidth.t(), float()) :: Bandwidth.t()
  defp ceiling(cap, k) do
    Bandwidth.bps(round(k * Bandwidth.as_bytes_per_sec(cap)))
  end

  # A monitor reading is nil until its first sample lands; an unmeasured metric is
  # treated as idle so a freshly booted node is still schedulable.
  @spec smoothed_float(Reading.t()) :: float()
  defp smoothed_float(%Reading{smoothed: nil}), do: 0.0
  defp smoothed_float(%Reading{smoothed: v}), do: v

  @spec smoothed_bandwidth(Reading.t()) :: Bandwidth.t()
  defp smoothed_bandwidth(%Reading{smoothed: nil}), do: Bandwidth.zero()
  defp smoothed_bandwidth(%Reading{smoothed: v}), do: v
end
