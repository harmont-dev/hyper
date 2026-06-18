defmodule Hyper.Vm.Instance do
  @moduledoc """
  Named instance types — fixed (vCPU, memory) sizes, like cloud instance classes.

  The caller picks a `type` instead of juggling raw numbers; this module turns it
  into host-side resource caps expressed as **firecracker jailer flags**.

  We run firecracker under the [jailer](https://github.com/firecracker-microvm/firecracker/blob/main/docs/jailer.md),
  which creates the cgroup (+ chroot, namespaces, privilege drop) and applies
  `--cgroup <file>=<value>` settings before exec'ing firecracker. `cgroup/1`
  returns those `--cgroup` args (cgroup **v2** only) ready to splice into the
  jailer command.
  """

  @typedoc "An instance size."
  @type t ::
          :micro
          | :milli
          | :centi
          | :deci
          | :base
          | :deca
          | :hecto
          | :kilo
          | :mega
          | :giga
          | :tera

  # Per-tier resource bundle, scaled linearly with vCPU:
  #   mem_mib    = 512 MiB / vCPU   (cgroup memory.max + guest mem_size_mib)
  #   disk_gb    = 8 GiB / vCPU     (rootfs capacity; sizes the image file)
  #   disk_mibps = 64 MiB/s / vCPU  (firecracker drive rate_limiter)
  #   net_mibps  = 32 MiB/s / vCPU  (firecracker NIC rate_limiter)
  # vCPUs may be fractional (CFS quota); the throughput/capacity units are binary.
  @specs %{
    micro: %{vcpus: 0.25, mem_mib: 128, disk_gb: 2, disk_mibps: 16, net_mibps: 8},
    milli: %{vcpus: 0.5, mem_mib: 256, disk_gb: 4, disk_mibps: 32, net_mibps: 16},
    centi: %{vcpus: 1, mem_mib: 512, disk_gb: 8, disk_mibps: 64, net_mibps: 32},
    deci: %{vcpus: 2, mem_mib: 1024, disk_gb: 16, disk_mibps: 128, net_mibps: 64},
    base: %{vcpus: 4, mem_mib: 2048, disk_gb: 32, disk_mibps: 256, net_mibps: 128},
    deca: %{vcpus: 8, mem_mib: 4096, disk_gb: 64, disk_mibps: 512, net_mibps: 256},
    hecto: %{vcpus: 16, mem_mib: 8192, disk_gb: 128, disk_mibps: 1024, net_mibps: 512},
    kilo: %{vcpus: 32, mem_mib: 16384, disk_gb: 256, disk_mibps: 2048, net_mibps: 1024},
    mega: %{vcpus: 64, mem_mib: 32768, disk_gb: 512, disk_mibps: 4096, net_mibps: 2048},
    giga: %{vcpus: 128, mem_mib: 65536, disk_gb: 1024, disk_mibps: 8192, net_mibps: 4096},
    tera: %{vcpus: 256, mem_mib: 131_072, disk_gb: 2048, disk_mibps: 16384, net_mibps: 8192}
  }

  # Standard CFS scheduling period (100ms). quota = vcpus * period.
  @cpu_period_us 100_000
  @mib 1024 * 1024

  @doc "All known instance types."
  @spec types() :: [t()]
  def types, do: Map.keys(@specs)

  @doc """
  The full resource bundle for a `type`. `vcpus`/`mem_mib` feed both the cgroup
  caps and firecracker's machine-config; `disk_gb` sizes the rootfs image; the
  `*_mibps` values feed firecracker's drive/NIC rate limiters.
  """
  @spec spec(t()) :: %{
          vcpus: number(),
          mem_mib: pos_integer(),
          disk_gb: pos_integer(),
          disk_mibps: pos_integer(),
          net_mibps: pos_integer()
        }
  def spec(type) when is_map_key(@specs, type), do: @specs[type]

  @doc """
  cgroup v2 caps for a `type`, as a map of cgroup file => value.

      iex> Hyper.Vm.Instance.cgroup(:micro)
      %{"cpu.max" => "25000 100000", "memory.max" => "134217728"}
  """
  @spec cgroup(t()) :: %{String.t() => String.t()}
  def cgroup(type) do
    %{vcpus: vcpus, mem_mib: mem_mib} = spec(type)

    %{
      "cpu.max" => "#{quota_us(vcpus)} #{@cpu_period_us}",
      "memory.max" => "#{mem_mib * @mib}"
    }
  end

  defp quota_us(vcpus), do: round(vcpus * @cpu_period_us)
end
