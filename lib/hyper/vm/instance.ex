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

  alias Hyper.Sys.Unit.Bandwidth
  alias Hyper.Sys.Unit.Information
  alias Hyper.Vm.Instance.Spec

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

  @specs %{
    micro: %Spec{vcpus: 0.25, mem: Information.mib(128), disk: Information.gib(2), disk_bw: Bandwidth.mibps(16), net_bw: Bandwidth.mibps(8)},
    milli: %Spec{vcpus: 0.5, mem: Information.mib(256), disk: Information.gib(4), disk_bw: Bandwidth.mibps(32), net_bw: Bandwidth.mibps(16)},
    centi: %Spec{vcpus: 1, mem: Information.mib(512), disk: Information.gib(8), disk_bw: Bandwidth.mibps(64), net_bw: Bandwidth.mibps(32)},
    deci: %Spec{vcpus: 2, mem: Information.mib(1024), disk: Information.gib(16), disk_bw: Bandwidth.mibps(128), net_bw: Bandwidth.mibps(64)},
    base: %Spec{vcpus: 4, mem: Information.mib(2048), disk: Information.gib(32), disk_bw: Bandwidth.mibps(256), net_bw: Bandwidth.mibps(128)},
    deca: %Spec{vcpus: 8, mem: Information.mib(4096), disk: Information.gib(64), disk_bw: Bandwidth.mibps(512), net_bw: Bandwidth.mibps(256)},
    hecto: %Spec{vcpus: 16, mem: Information.mib(8192), disk: Information.gib(128), disk_bw: Bandwidth.mibps(1024), net_bw: Bandwidth.mibps(512)},
    kilo: %Spec{vcpus: 32, mem: Information.mib(16_384), disk: Information.gib(256), disk_bw: Bandwidth.mibps(2048), net_bw: Bandwidth.mibps(1024)},
    mega: %Spec{vcpus: 64, mem: Information.mib(32_768), disk: Information.gib(512), disk_bw: Bandwidth.mibps(4096), net_bw: Bandwidth.mibps(2048)},
    giga: %Spec{vcpus: 128, mem: Information.mib(65_536), disk: Information.gib(1024), disk_bw: Bandwidth.mibps(8192), net_bw: Bandwidth.mibps(4096)},
    tera: %Spec{vcpus: 256, mem: Information.mib(131_072), disk: Information.gib(2048), disk_bw: Bandwidth.mibps(16_384), net_bw: Bandwidth.mibps(8192)}
  }

  @doc "All known instance types."
  @spec types() :: [t()]
  def types, do: Map.keys(@specs)

  @doc """
  The full resource bundle for a `type`. `vcpus` and `mem` feed both the cgroup
  caps and firecracker's machine-config; `disk` sizes the rootfs image; the
  `disk_bw`/`net_bw` throughputs feed firecracker's drive/NIC rate limiters.
  """
  @spec spec(t()) :: Spec.t()
  def spec(type) when is_map_key(@specs, type), do: @specs[type]
end
