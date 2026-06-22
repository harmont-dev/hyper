defmodule Hyper.Node.FireVMM.BootSpec do
  @moduledoc """
  Resolves a `Hyper.Vm.source()` + instance `type` into a concrete, API-shaped
  cold-boot spec the `:configuring` state issues: machine config (from the
  instance type), a kernel boot source, and a root drive.
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

  @spec resolve(Hyper.Vm.source(), Instance.t()) :: Cold.t()
  def resolve(source, type) when is_map(source) do
    %Cold{
      machine_config: Instance.Spec.machine_config(Instance.spec(type)),
      boot_source: %BootSource{
        kernel_image_path: Map.fetch!(source, :kernel_image_path),
        boot_args: Map.get(source, :boot_args, @default_boot_args)
      },
      drives: [
        %Drive{
          drive_id: "rootfs",
          is_root_device: true,
          is_read_only: false,
          path_on_host: Map.fetch!(source, :root_drive_path)
        }
      ]
    }
  end
end
