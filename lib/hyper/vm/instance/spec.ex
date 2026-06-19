defmodule Hyper.Vm.Instance.Spec do
  @moduledoc "Resource bundle for one instance type."

  @type t :: %__MODULE__{
          vcpus: number(),
          mem: Unit.Information.t(),
          disk: Unit.Information.t(),
          disk_bw: Unit.Bandwidth.t(),
          net_bw: Unit.Bandwidth.t()
        }

  defstruct [:vcpus, :mem, :disk, :disk_bw, :net_bw]

  @spec cgroup_v2(t()) :: Hyper.Sys.Linux.Cgroup.V2.Config.t()
  def cgroup_v2(spec) do
    alias Hyper.Sys.Linux.Cgroup.V2.Config
    alias Unit.Time

    period_us = Time.as_us(Hyper.Node.FireVMM.cpu_period())
    quota_us = round(spec.vcpus * period_us)

    Config.new()
    |> Config.cpu_max(quota_us, period_us)
    |> Config.memory_max(Unit.Information.as_bytes(spec.mem))
  end
end
