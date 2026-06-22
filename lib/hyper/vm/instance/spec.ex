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
  Firecracker machine-config for this spec, the guest-facing analog of
  `cgroup_v2/1`. `vcpus` is a fractional cgroup quota; the guest needs a positive
  integer count, so it's rounded up and floored at 1 (a 0.25-vCPU `:micro` still
  presents one vCPU). Memory is the spec's `mem` in MiB.
  """
  @spec machine_config(t()) :: Hyper.Firecracker.Api.MachineConfiguration.t()
  def machine_config(spec) do
    %Hyper.Firecracker.Api.MachineConfiguration{
      vcpu_count: max(1, ceil(spec.vcpus)),
      mem_size_mib: Unit.Information.as_mib(spec.mem)
    }
  end
end
