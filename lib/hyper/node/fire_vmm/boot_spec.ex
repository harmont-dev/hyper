defmodule Hyper.Node.FireVMM.BootSpec do
  @moduledoc """
  Resolves a `Hyper.Vm.source()` + instance `type` + `arch` into a concrete,
  API-shaped cold-boot spec the `:configuring` state issues: machine config
  (from the instance type), the guest CPU config, a kernel boot source, and a
  root drive.
  """

  alias Hyper.Firecracker.Api.{BootSource, CpuConfig, Drive, MachineConfiguration}
  alias Hyper.Node.FireVMM.GuestCpu
  alias Hyper.Vm.Instance

  # Default cmdline. No `console=`: serial printk is synchronous at 115200 baud
  # and blocks the boot vCPU on every kernel line, dominating cold-boot wall
  # time. Guest output travels over vsock, not the console, so a silent boot
  # loses nothing operationally; a debug boot re-adds `console=ttyS0` via the
  # per-VM `boot_args` override. `init=/hyper-init` runs our PID-1 guest agent
  # instead of the image's own init (which for a bare OCI rootfs spins on a
  # missing /sbin/openrc). Firecracker appends `root=/dev/vda rw` + virtio_mmio.
  @default_boot_args "reboot=k panic=1 pci=off init=/hyper-init"

  defmodule Cold do
    @moduledoc """
    A resolved cold boot. `cpu_config` is `nil` where the guest boots with
    Firecracker's default CPU config.
    """
    @enforce_keys [:machine_config, :boot_source, :drives]
    defstruct [:machine_config, :cpu_config, :boot_source, drives: [], network_interfaces: []]

    @type t :: %__MODULE__{
            machine_config: MachineConfiguration.t(),
            cpu_config: CpuConfig.t() | nil,
            boot_source: BootSource.t(),
            drives: [Drive.t()],
            network_interfaces: [Hyper.Firecracker.Api.NetworkInterface.t()]
          }
  end

  @spec resolve(Hyper.Vm.source(), Instance.t(), Instance.arch()) :: Cold.t()
  def resolve(source, type, arch) when is_map(source) do
    # Networking is mandatory: every VM gets a NIC on the uniform inner-world
    # address plus the kernel `ip=`/`hyper.resolver=` cmdline. A node that
    # reached here has already passed the startup network preflight.
    vm_id = Map.fetch!(source, :vm_id)

    boot_args =
      Map.get(source, :boot_args, @default_boot_args) <>
        " " <>
        Hyper.Node.FireVMM.Net.ip_cmdline() <>
        " " <> Hyper.Node.FireVMM.Net.resolver_cmdline(Hyper.Cfg.Network.resolver())

    %Cold{
      machine_config: Instance.Spec.machine_config(Instance.spec(type)),
      cpu_config: GuestCpu.config(arch),
      boot_source: %BootSource{
        kernel_image_path: Map.fetch!(source, :kernel_image_path),
        boot_args: boot_args
      },
      drives: [
        %Drive{
          drive_id: "rootfs",
          is_root_device: true,
          is_read_only: false,
          path_on_host: Map.fetch!(source, :root_drive_path)
        }
      ],
      network_interfaces: [Hyper.Node.FireVMM.Net.interface(vm_id)]
    }
  end
end
