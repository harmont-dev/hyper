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

  @spec cgroup_v2(t()) :: Sys.Linux.Cgroup.V2.Config.t()
  def cgroup_v2(spec) do
    alias Sys.Linux.Cgroup.V2.Config
    alias Unit.Time

    period_us = Time.as_us(Hyper.Node.FireVMM.cpu_period())
    quota_us = round(spec.vcpus * period_us)

    Config.new()
    |> Config.cpu_max(quota_us, period_us)
    |> Config.memory_max(Unit.Information.as_bytes(spec.mem))
  end

  @doc """
  Guest-visible vCPU count for firecracker's machine-config. `vcpus` is a
  fractional cgroup quota (see `cgroup_v2/1`); the guest needs a positive
  integer, so round up and floor at 1 - a 0.25-vCPU `:micro` still presents one
  vCPU to the guest.
  """
  @spec vcpu_count(t()) :: pos_integer()
  def vcpu_count(spec), do: max(1, ceil(spec.vcpus))

  @doc "Guest memory size, in MiB, for firecracker's machine-config."
  @spec mem_mib(t()) :: non_neg_integer()
  def mem_mib(spec), do: Unit.Information.as_mib(spec.mem)
end
