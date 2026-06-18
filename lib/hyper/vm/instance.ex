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

  alias Hyper.Sys.Unit.Bw
  alias Hyper.Sys.Unit.Bytes
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
    micro: %Spec{vcpus: 0.25, mem: Bytes.mib(128), disk: Bytes.gib(2), disk_bw: Bw.mibps(16), net_bw: Bw.mibps(8)},
    milli: %Spec{vcpus: 0.5, mem: Bytes.mib(256), disk: Bytes.gib(4), disk_bw: Bw.mibps(32), net_bw: Bw.mibps(16)},
    centi: %Spec{vcpus: 1, mem: Bytes.mib(512), disk: Bytes.gib(8), disk_bw: Bw.mibps(64), net_bw: Bw.mibps(32)},
    deci: %Spec{vcpus: 2, mem: Bytes.mib(1024), disk: Bytes.gib(16), disk_bw: Bw.mibps(128), net_bw: Bw.mibps(64)},
    base: %Spec{vcpus: 4, mem: Bytes.mib(2048), disk: Bytes.gib(32), disk_bw: Bw.mibps(256), net_bw: Bw.mibps(128)},
    deca: %Spec{vcpus: 8, mem: Bytes.mib(4096), disk: Bytes.gib(64), disk_bw: Bw.mibps(512), net_bw: Bw.mibps(256)},
    hecto: %Spec{vcpus: 16, mem: Bytes.mib(8192), disk: Bytes.gib(128), disk_bw: Bw.mibps(1024), net_bw: Bw.mibps(512)},
    kilo: %Spec{vcpus: 32, mem: Bytes.mib(16384), disk: Bytes.gib(256), disk_bw: Bw.mibps(2048), net_bw: Bw.mibps(1024)},
    mega: %Spec{vcpus: 64, mem: Bytes.mib(32768), disk: Bytes.gib(512), disk_bw: Bw.mibps(4096), net_bw: Bw.mibps(2048)},
    giga: %Spec{vcpus: 128, mem: Bytes.mib(65536), disk: Bytes.gib(1024), disk_bw: Bw.mibps(8192), net_bw: Bw.mibps(4096)},
    tera: %Spec{vcpus: 256, mem: Bytes.mib(131_072), disk: Bytes.gib(2048), disk_bw: Bw.mibps(16384), net_bw: Bw.mibps(8192)}
  }

  @doc "All known instance types."
  @spec types() :: [t()]
  def types, do: Map.keys(@specs)

  @doc """
  The full resource bundle for a `type`. `vcpus`/`mem_mib` feed both the cgroup
  caps and firecracker's machine-config; `disk_gb` sizes the rootfs image; the
  `*_mibps` values feed firecracker's drive/NIC rate limiters.
  """
  @spec spec(t()) :: Spec.t()
  def spec(type) when is_map_key(@specs, type), do: @specs[type]
end
