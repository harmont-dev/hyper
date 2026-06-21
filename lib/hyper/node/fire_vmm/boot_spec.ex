defmodule Hyper.Node.FireVMM.BootSpec do
  @moduledoc """
  Resolves a `Hyper.vm_source()` + instance `type` into a concrete, API-shaped
  boot specification the `Hyper.Node.FireVMM.Boot` flow can execute.

  Two shapes:

    * `Cold` - a fresh boot: machine config (from the instance type), a kernel
      boot source, and a root drive. Used to mint the first snapshot.
    * `Restore` - resume a saved guest from a snapshot directory.

  Flow-only: the artifact paths it copies into the schemas must already be
  visible inside the VM's jail. This module does no host staging, image
  activation, or networking.
  """

  alias Hyper.Firecracker.Api.{BootSource, Drive, MachineConfiguration, SnapshotLoadParams}
  alias Hyper.Vm.Instance
  alias Unit.Information

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

  defmodule Restore do
    @moduledoc "A resolved snapshot restore."
    @enforce_keys [:params]
    defstruct [:params]
    @type t :: %__MODULE__{params: SnapshotLoadParams.t()}
  end

  @spec resolve(Hyper.vm_source(), Instance.t()) :: {:ok, Cold.t() | Restore.t()} | {:error, term()}
  def resolve({:cold, cold}, type) when is_map(cold) do
    {:ok,
     %Cold{
       machine_config: machine_config(type),
       boot_source: %BootSource{
         kernel_image_path: Map.fetch!(cold, :kernel_image_path),
         boot_args: Map.get(cold, :boot_args, @default_boot_args)
       },
       drives: [
         %Drive{
           drive_id: "rootfs",
           is_root_device: true,
           is_read_only: Map.get(cold, :read_only, false),
           path_on_host: Map.fetch!(cold, :root_drive_path)
         }
       ]
     }}
  end

  def resolve({:snapshot, dir}, _type) do
    {:ok,
     %Restore{
       params: %SnapshotLoadParams{
         snapshot_path: Path.join(dir, "snapshot"),
         mem_file_path: Path.join(dir, "mem"),
         resume_vm: true
       }
     }}
  end

  def resolve({:vm, _vm}, _type), do: {:error, {:unsupported_source, :vm}}

  # Instance vCPU caps are fractional (cgroup quota); Firecracker needs a positive
  # integer vCPU count, so ceil and floor at 1.
  @spec machine_config(Instance.t()) :: MachineConfiguration.t()
  defp machine_config(type) do
    spec = Instance.spec(type)

    %MachineConfiguration{
      vcpu_count: max(1, ceil(spec.vcpus)),
      mem_size_mib: Information.as_mib(spec.mem)
    }
  end
end
