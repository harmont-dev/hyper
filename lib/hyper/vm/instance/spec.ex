defmodule Hyper.Vm.Instance.Spec do
  @moduledoc "Resource bundle for one instance type."

  use Unit.Operators

  alias Unit.Information

  # Firecracker's heap and stacks plus the kernel's slab for the VM: 10 MiB measured on a :micro.
  @vmm_overhead Information.mib(16)
  # Host page tables and EPT each take ~0.2% of guest RAM, so 1/64 leaves 4x margin.
  @page_table_divisor 64
  # Dirty host page cache that reclaim must write back before dropping it, while memory.high
  # throttles the writer.
  @dirty_cache_headroom Information.mib(32)

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

    high = host_mem(spec)

    Config.new()
    |> Config.cpu_max(quota_us, period_us)
    |> Config.memory_high(Information.as_bytes(high))
    |> Config.memory_max(Information.as_bytes(high + @dirty_cache_headroom))
  end

  @spec host_mem(t()) :: Unit.Information.t()
  def host_mem(spec) do
    page_tables = Information.bytes(div(Information.as_bytes(spec.mem), @page_table_divisor))
    spec.mem + page_tables + @vmm_overhead
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
