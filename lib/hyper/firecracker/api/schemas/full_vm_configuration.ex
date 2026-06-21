defmodule Hyper.Firecracker.Api.FullVmConfiguration do
  @moduledoc """
  Provides struct and type for a FullVmConfiguration
  """
  use Hyper.Firecracker.Api.Encoder

  @type t :: %__MODULE__{
          __info__: map,
          balloon: Hyper.Firecracker.Api.Balloon.t() | nil,
          boot_source: Hyper.Firecracker.Api.BootSource.t() | nil,
          cpu_config: Hyper.Firecracker.Api.CpuConfig.t() | nil,
          drives: [Hyper.Firecracker.Api.Drive.t()] | nil,
          entropy: Hyper.Firecracker.Api.EntropyDevice.t() | nil,
          logger: Hyper.Firecracker.Api.Logger.t() | nil,
          machine_config: Hyper.Firecracker.Api.MachineConfiguration.t() | nil,
          memory_hotplug: Hyper.Firecracker.Api.MemoryHotplugConfig.t() | nil,
          metrics: Hyper.Firecracker.Api.Metrics.t() | nil,
          mmds_config: Hyper.Firecracker.Api.MmdsConfig.t() | nil,
          network_interfaces: [Hyper.Firecracker.Api.NetworkInterface.t()] | nil,
          pmem: [Hyper.Firecracker.Api.Pmem.t()] | nil,
          vsock: Hyper.Firecracker.Api.Vsock.t() | nil
        }

  defstruct [
    :__info__,
    :balloon,
    :boot_source,
    :cpu_config,
    :drives,
    :entropy,
    :logger,
    :machine_config,
    :memory_hotplug,
    :metrics,
    :mmds_config,
    :network_interfaces,
    :pmem,
    :vsock
  ]

  @doc false
  @spec __fields__(atom) :: keyword
  def __fields__(type \\ :t)

  def __fields__(:t) do
    [
      balloon: {Hyper.Firecracker.Api.Balloon, :t},
      boot_source: {Hyper.Firecracker.Api.BootSource, :t},
      cpu_config: {Hyper.Firecracker.Api.CpuConfig, :t},
      drives: [{Hyper.Firecracker.Api.Drive, :t}],
      entropy: {Hyper.Firecracker.Api.EntropyDevice, :t},
      logger: {Hyper.Firecracker.Api.Logger, :t},
      machine_config: {Hyper.Firecracker.Api.MachineConfiguration, :t},
      memory_hotplug: {Hyper.Firecracker.Api.MemoryHotplugConfig, :t},
      metrics: {Hyper.Firecracker.Api.Metrics, :t},
      mmds_config: {Hyper.Firecracker.Api.MmdsConfig, :t},
      network_interfaces: [{Hyper.Firecracker.Api.NetworkInterface, :t}],
      pmem: [{Hyper.Firecracker.Api.Pmem, :t}],
      vsock: {Hyper.Firecracker.Api.Vsock, :t}
    ]
  end
end
