defmodule Hyper.Vm.Instance do
  @moduledoc """
  Named instance types — fixed (vCPU, memory) sizes, like cloud instance classes.

  The caller picks a `type` instead of juggling raw numbers; this module turns it
  into host-side resource caps expressed as **firecracker jailer flags**.

  We run firecracker under the [jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md),
  which creates the cgroup (+ chroot, namespaces, privilege drop) and applies
  `--cgroup <file>=<value>` settings before exec'ing firecracker. `cgroup/2`
  returns those `--cgroup` args ready to splice into the jailer command. The
  jailer supports cgroup **v2** natively, so we default there.
  """

  @typedoc "An instance size."
  @type t :: :nano | :micro | :small | :medium | :large

  @typedoc "cgroup hierarchy the jailer should target."
  @type cgroup_version :: 1 | 2

  # vCPUs may be fractional (CFS quota); memory is whole MiB.
  @specs %{
    nano: %{vcpus: 0.25, mem_mib: 128},
    micro: %{vcpus: 0.5, mem_mib: 256},
    small: %{vcpus: 1, mem_mib: 512},
    medium: %{vcpus: 2, mem_mib: 1024},
    large: %{vcpus: 4, mem_mib: 2048}
  }

  # Standard CFS scheduling period (100ms). quota = vcpus * period.
  @cpu_period_us 100_000
  @mib 1024 * 1024

  @doc "All known instance types."
  @spec types() :: [t()]
  def types, do: Map.keys(@specs)

  @doc "The (vCPUs, memory) spec for a type — feeds both this cap and firecracker's machine-config."
  @spec spec(t()) :: %{vcpus: number(), mem_mib: pos_integer()}
  def spec(type) when is_map_key(@specs, type), do: @specs[type]

  @doc """
  Jailer `--cgroup` flags capping a `type`. `version` selects the cgroup file
  names (v2 default).

      iex> Hyper.Vm.Instance.cgroup(:micro)
      ["--cgroup", "cpu.max=50000 100000", "--cgroup", "memory.max=268435456"]

      iex> Hyper.Vm.Instance.cgroup(:micro, 1)
      ["--cgroup", "cpu.cfs_period_us=100000", "--cgroup", "cpu.cfs_quota_us=50000", "--cgroup", "memory.limit_in_bytes=268435456"]
  """
  @spec cgroup(t(), cgroup_version()) :: [String.t()]
  def cgroup(type, version \\ 2)

  def cgroup(type, 2) do
    %{vcpus: vcpus, mem_mib: mem_mib} = spec(type)

    flags([
      {"cpu.max", "#{quota_us(vcpus)} #{@cpu_period_us}"},
      {"memory.max", "#{mem_mib * @mib}"}
    ])
  end

  def cgroup(type, 1) do
    %{vcpus: vcpus, mem_mib: mem_mib} = spec(type)

    flags([
      {"cpu.cfs_period_us", "#{@cpu_period_us}"},
      {"cpu.cfs_quota_us", "#{quota_us(vcpus)}"},
      {"memory.limit_in_bytes", "#{mem_mib * @mib}"}
    ])
  end

  defp quota_us(vcpus), do: round(vcpus * @cpu_period_us)

  defp flags(pairs), do: Enum.flat_map(pairs, fn {file, value} -> ["--cgroup", "#{file}=#{value}"] end)
end
