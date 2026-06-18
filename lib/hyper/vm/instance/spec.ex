defmodule Hyper.Vm.Instance.Spec do
  @moduledoc "Resource bundle for one instance type."

  @type t :: %__MODULE__{
          vcpus: number(),
          mem: pos_integer(),
          disk: pos_integer(),
          disk_bw: pos_integer(),
          net_bw: pos_integer()
        }

  defstruct [:vcpus, :mem, :disk, :disk_bw, :net_bw]

  @spec cgroup_v2(t()) :: Hyper.Sys.Linux.Cgroup.V2.Config.t()
  def cgroup_v2(spec) do
    alias Hyper.Sys.Linux.Cgroup.V2.Config

    Config.new()
    |> Config.cpu_max(round(spec.vcpus * Hyper.Node.FireVMM.cpu_period()), Hyper.Node.FireVMM.cpu_period())
    |> Config.memory_max(spec.mem)
  end
end
