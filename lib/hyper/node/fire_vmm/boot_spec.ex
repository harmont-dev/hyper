defmodule Hyper.Node.FireVMM.BootSpec do
  @moduledoc """
  Resolves a `Hyper.vm_source()` + instance `type` into a concrete, API-shaped
  cold-boot spec the `:configuring` state issues: machine config (from the
  instance type), a kernel boot source, and a root drive.

  Flow-only: the artifact paths it copies into the schemas must already be
  visible inside the VM's jail. This module does no host staging, image
  activation, or networking.
  """

  alias Hyper.Firecracker.Api.{BootSource, Drive, MachineConfiguration}
  alias Hyper.Vm.Instance

  # Standard Firecracker serial-console kernel cmdline.
  @default_boot_args "console=ttyS0 reboot=k panic=1 pci=off"

  defmodule Cold do
    @moduledoc "A resolved cold boot."
    @enforce_keys [:machine_config, :boot_source, :drives]
    defstruct [:machine_config, :boot_source, drives: [], network_interfaces: []]

    @type t :: %__MODULE__{
            machine_config: MachineConfiguration.t(),
            boot_source: BootSource.t(),
            drives: [Drive.t()],
            network_interfaces: [Hyper.Firecracker.Api.NetworkInterface.t()]
          }
  end

  @spec resolve(Hyper.vm_source(), Instance.t()) :: Cold.t()
  def resolve(source, type) when is_map(source) do
    %Cold{
      machine_config: machine_config(type),
      boot_source: %BootSource{
        kernel_image_path: Map.fetch!(source, :kernel_image_path),
        boot_args: Map.get(source, :boot_args, @default_boot_args)
      },
      drives: [
        %Drive{
          drive_id: "rootfs",
          is_root_device: true,
          is_read_only: Map.get(source, :read_only, false),
          path_on_host: Map.fetch!(source, :root_drive_path)
        }
      ]
    }
  end

  # The vCPU/mem derivations (fractional cgroup quota -> guest-visible integer
  # count; mem -> MiB) are instance-domain rules and live on Instance.Spec; here
  # we only assemble them into firecracker's machine-config struct.
  @spec machine_config(Instance.t()) :: MachineConfiguration.t()
  defp machine_config(type) do
    spec = Instance.spec(type)

    %MachineConfiguration{
      vcpu_count: Instance.Spec.vcpu_count(spec),
      mem_size_mib: Instance.Spec.mem_mib(spec)
    }
  end
end
