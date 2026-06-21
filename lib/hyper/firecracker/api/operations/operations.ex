defmodule Hyper.Firecracker.Api.Operations do
  @moduledoc """
  Provides API endpoints related to operations
  """

  @default_client Hyper.Firecracker.Api.Transport

  @doc """
  Creates a full or diff snapshot. Post-boot only.

  Creates a snapshot of the microVM state. The microVM should be in the `Paused` state.

  ## Request Body

  **Content Types**: `application/json`

  The configuration used for creating a snapshot.
  """
  @spec create_snapshot(body :: Hyper.Firecracker.Api.SnapshotCreateParams.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def create_snapshot(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :create_snapshot},
      url: "/snapshot/create",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.SnapshotCreateParams, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates a synchronous action.

  ## Request Body

  **Content Types**: `application/json`
  """
  @spec create_sync_action(body :: Hyper.Firecracker.Api.InstanceActionInfo.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def create_sync_action(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :create_sync_action},
      url: "/actions",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.InstanceActionInfo, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Returns the current balloon device configuration.
  """
  @spec describe_balloon_config(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.Balloon.t()} | {:error, Hyper.Firecracker.Api.Error.t()}
  def describe_balloon_config(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :describe_balloon_config},
      url: "/balloon",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.Balloon, :t}},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Returns the balloon hinting statistics, only if enabled pre-boot.
  """
  @spec describe_balloon_hinting(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.BalloonHintingStatus.t()}
          | {:error, Hyper.Firecracker.Api.Error.t()}
  def describe_balloon_hinting(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :describe_balloon_hinting},
      url: "/balloon/hinting/status",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.BalloonHintingStatus, :t}},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Returns the latest balloon device statistics, only if enabled pre-boot.
  """
  @spec describe_balloon_stats(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.BalloonStats.t()}
          | {:error, Hyper.Firecracker.Api.Error.t()}
  def describe_balloon_stats(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :describe_balloon_stats},
      url: "/balloon/statistics",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.BalloonStats, :t}},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Returns general information about an instance.
  """
  @spec describe_instance(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.InstanceInfo.t()}
          | {:error, Hyper.Firecracker.Api.Error.t()}
  def describe_instance(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :describe_instance},
      url: "/",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.InstanceInfo, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Gets the full VM configuration.

  Gets configuration for all VM resources. If the VM is restored from a snapshot, the boot-source, machine-config.smt and machine-config.cpu_template will be empty.
  """
  @spec get_export_vm_config(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.FullVmConfiguration.t()}
          | {:error, Hyper.Firecracker.Api.Error.t()}
  def get_export_vm_config(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :get_export_vm_config},
      url: "/vm/config",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.FullVmConfiguration, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Gets the Firecracker version.
  """
  @spec get_firecracker_version(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.FirecrackerVersion.t()}
          | {:error, Hyper.Firecracker.Api.Error.t()}
  def get_firecracker_version(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :get_firecracker_version},
      url: "/version",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.FirecrackerVersion, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Gets the machine configuration of the VM.

  Gets the machine configuration of the VM. When called before the PUT operation, it will return the default values for the vCPU count (=1), memory size (=128 MiB). By default SMT is disabled and there is no CPU Template.
  """
  @spec get_machine_configuration(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.MachineConfiguration.t()}
          | {:error, Hyper.Firecracker.Api.Error.t()}
  def get_machine_configuration(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :get_machine_configuration},
      url: "/machine-config",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.MachineConfiguration, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Retrieves the status of the hotpluggable memory

  Reuturn the status of the hotpluggable memory. This can be used to follow the progress of the guest after a PATCH API.
  """
  @spec get_memory_hotplug(opts :: keyword) ::
          {:ok, Hyper.Firecracker.Api.MemoryHotplugStatus.t()}
          | {:error, Hyper.Firecracker.Api.Error.t()}
  def get_memory_hotplug(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :get_memory_hotplug},
      url: "/hotplug/memory",
      method: :get,
      response: [
        {200, {Hyper.Firecracker.Api.MemoryHotplugStatus, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Get the MMDS data store.
  """
  @spec get_mmds(opts :: keyword) :: {:ok, map} | {:error, Hyper.Firecracker.Api.Error.t()}
  def get_mmds(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :get_mmds},
      url: "/mmds",
      method: :get,
      response: [
        {200, :map},
        {404, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Loads a snapshot. Pre-boot only.

  Loads the microVM state from a snapshot. Only accepted on a fresh Firecracker process (before configuring any resource other than the Logger and Metrics).

  ## Request Body

  **Content Types**: `application/json`

  The configuration used for loading a snapshot.
  """
  @spec load_snapshot(body :: Hyper.Firecracker.Api.SnapshotLoadParams.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def load_snapshot(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :load_snapshot},
      url: "/snapshot/load",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.SnapshotLoadParams, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates a balloon device.

  Updates an existing balloon device, before or after machine startup. Will fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Balloon properties
  """
  @spec patch_balloon(body :: Hyper.Firecracker.Api.BalloonUpdate.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_balloon(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_balloon},
      url: "/balloon",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.BalloonUpdate, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates a balloon device statistics polling interval.

  Updates an existing balloon device statistics interval, before or after machine startup. Will fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Balloon properties
  """
  @spec patch_balloon_stats_interval(
          body :: Hyper.Firecracker.Api.BalloonStatsUpdate.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_balloon_stats_interval(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_balloon_stats_interval},
      url: "/balloon/statistics",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.BalloonStatsUpdate, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates the properties of a drive. Post-boot only.

  Updates the properties of the drive with the ID specified by drive_id path parameter. Will fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Guest drive properties
  """
  @spec patch_guest_drive_by_id(
          drive_id :: String.t(),
          body :: Hyper.Firecracker.Api.PartialDrive.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_guest_drive_by_id(drive_id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [drive_id: drive_id, body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_guest_drive_by_id},
      url: "/drives/#{drive_id}",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.PartialDrive, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates the rate limiters applied to a network interface. Post-boot only.

  Updates the rate limiters applied to a network interface.

  ## Request Body

  **Content Types**: `application/json`

  A subset of the guest network interface properties
  """
  @spec patch_guest_network_interface_by_id(
          iface_id :: String.t(),
          body :: Hyper.Firecracker.Api.PartialNetworkInterface.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_guest_network_interface_by_id(iface_id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [iface_id: iface_id, body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_guest_network_interface_by_id},
      url: "/network-interfaces/#{iface_id}",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.PartialNetworkInterface, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates the rate limiter of a pmem device. Post-boot only.

  Updates the rate limiter applied to the pmem device with the ID specified by the id path parameter.

  ## Request Body

  **Content Types**: `application/json`

  Pmem rate limiter properties
  """
  @spec patch_guest_pmem_by_id(
          id :: String.t(),
          body :: Hyper.Firecracker.Api.PartialPmem.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_guest_pmem_by_id(id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [id: id, body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_guest_pmem_by_id},
      url: "/pmem/#{id}",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.PartialPmem, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Partially updates the Machine Configuration of the VM. Pre-boot only.

  Partially updates the Virtual Machine Configuration with the specified input. If any of the parameters has an incorrect value, the whole update fails.

  ## Request Body

  **Content Types**: `application/json`

  A subset of Machine Configuration Parameters
  """
  @spec patch_machine_configuration(
          body :: Hyper.Firecracker.Api.MachineConfiguration.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_machine_configuration(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_machine_configuration},
      url: "/machine-config",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.MachineConfiguration, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates the size of the hotpluggable memory region

  Updates the size of the hotpluggable memory region. The guest will plug and unplug memory to hit the requested memory.

  ## Request Body

  **Content Types**: `application/json`

  Hotpluggable memory size update
  """
  @spec patch_memory_hotplug(
          body :: Hyper.Firecracker.Api.MemoryHotplugSizeUpdate.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_memory_hotplug(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_memory_hotplug},
      url: "/hotplug/memory",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.MemoryHotplugSizeUpdate, :t}}],
      response: [{204, :null}, default: {Hyper.Firecracker.Api.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Updates the MMDS data store.

  ## Request Body

  **Content Types**: `application/json`

  The MMDS data store patch JSON.
  """
  @spec patch_mmds(body :: map, opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_mmds(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_mmds},
      url: "/mmds",
      body: body,
      method: :patch,
      request: [{"application/json", :map}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates the microVM state.

  Sets the desired state (Paused or Resumed) for the microVM.

  ## Request Body

  **Content Types**: `application/json`

  The microVM state
  """
  @spec patch_vm(body :: Hyper.Firecracker.Api.Vm.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def patch_vm(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :patch_vm},
      url: "/vm",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.Vm, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates or updates a balloon device.

  Creates a new balloon device if one does not already exist, otherwise updates it, before machine startup. This will fail after machine startup. Will fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Balloon properties
  """
  @spec put_balloon(body :: Hyper.Firecracker.Api.Balloon.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_balloon(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_balloon},
      url: "/balloon",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.Balloon, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Configures CPU features flags for the vCPUs of the guest VM. Pre-boot only.

  Provides configuration to the Firecracker process to specify vCPU resource configuration prior to launching the guest machine.

  ## Request Body

  **Content Types**: `application/json`

  CPU configuration request
  """
  @spec put_cpu_configuration(body :: Hyper.Firecracker.Api.CpuConfig.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_cpu_configuration(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_cpu_configuration},
      url: "/cpu-config",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.CpuConfig, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates an entropy device. Pre-boot only.

  Enables an entropy device that provides high-quality random data to the guest.

  ## Request Body

  **Content Types**: `application/json`

  Guest entropy device properties
  """
  @spec put_entropy_device(body :: Hyper.Firecracker.Api.EntropyDevice.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_entropy_device(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_entropy_device},
      url: "/entropy",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.EntropyDevice, :t}}],
      response: [{204, :null}, default: {Hyper.Firecracker.Api.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Creates or updates the boot source. Pre-boot only.

  Creates new boot source if one does not already exist, otherwise updates it. Will fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Guest boot source properties
  """
  @spec put_guest_boot_source(body :: Hyper.Firecracker.Api.BootSource.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_guest_boot_source(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_guest_boot_source},
      url: "/boot-source",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.BootSource, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates or updates a drive. Pre-boot only.

  Creates new drive with ID specified by drive_id path parameter. If a drive with the specified ID already exists, updates its state based on new input. Will fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Guest drive properties
  """
  @spec put_guest_drive_by_id(
          drive_id :: String.t(),
          body :: Hyper.Firecracker.Api.Drive.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_guest_drive_by_id(drive_id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [drive_id: drive_id, body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_guest_drive_by_id},
      url: "/drives/#{drive_id}",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.Drive, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates a network interface. Pre-boot only.

  Creates new network interface with ID specified by iface_id path parameter.

  ## Request Body

  **Content Types**: `application/json`

  Guest network interface properties
  """
  @spec put_guest_network_interface_by_id(
          iface_id :: String.t(),
          body :: Hyper.Firecracker.Api.NetworkInterface.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_guest_network_interface_by_id(iface_id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [iface_id: iface_id, body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_guest_network_interface_by_id},
      url: "/network-interfaces/#{iface_id}",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.NetworkInterface, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates or updates a pmem device. Pre-boot only.

  Creates new pmem device with ID specified by id parameter. If a pmem device with the specified ID already exists, updates its state based on new input. Will fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Guest pmem device properties
  """
  @spec put_guest_pmem_by_id(
          id :: String.t(),
          body :: Hyper.Firecracker.Api.Pmem.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_guest_pmem_by_id(id, body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [id: id, body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_guest_pmem_by_id},
      url: "/pmem/#{id}",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.Pmem, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates/updates a vsock device. Pre-boot only.

  The first call creates the device with the configuration specified in body. Subsequent calls will update the device configuration. May fail if update is not possible.

  ## Request Body

  **Content Types**: `application/json`

  Guest vsock properties
  """
  @spec put_guest_vsock(body :: Hyper.Firecracker.Api.Vsock.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_guest_vsock(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_guest_vsock},
      url: "/vsock",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.Vsock, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Initializes the logger by specifying a named pipe or a file for the logs output.

  ## Request Body

  **Content Types**: `application/json`

  Logging system description
  """
  @spec put_logger(body :: Hyper.Firecracker.Api.Logger.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_logger(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_logger},
      url: "/logger",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.Logger, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Updates the Machine Configuration of the VM. Pre-boot only.

  Updates the Virtual Machine Configuration with the specified input. Firecracker starts with default values for vCPU count (=1) and memory size (=128 MiB). The vCPU count is restricted to the [1, 32] range. With SMT enabled, the vCPU count is required to be either 1 or an even number in the range. otherwise there are no restrictions regarding the vCPU count. If 2M hugetlbfs pages are specified, then `mem_size_mib` must be a multiple of 2. If any of the parameters has an incorrect value, the whole update fails. All parameters that are optional and are not specified are set to their default values (smt = false, track_dirty_pages = false, cpu_template = None, huge_pages = None).

  ## Request Body

  **Content Types**: `application/json`

  Machine Configuration Parameters
  """
  @spec put_machine_configuration(
          body :: Hyper.Firecracker.Api.MachineConfiguration.t(),
          opts :: keyword
        ) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_machine_configuration(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_machine_configuration},
      url: "/machine-config",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.MachineConfiguration, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Configures the hotpluggable memory

  Configure the hotpluggable memory, which is a virtio-mem device, with an associated memory area that can be hot(un)plugged in the guest on demand using the PATCH API.

  ## Request Body

  **Content Types**: `application/json`

  Hotpluggable memory configuration
  """
  @spec put_memory_hotplug(body :: Hyper.Firecracker.Api.MemoryHotplugConfig.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_memory_hotplug(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_memory_hotplug},
      url: "/hotplug/memory",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.MemoryHotplugConfig, :t}}],
      response: [{204, :null}, default: {Hyper.Firecracker.Api.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Initializes the metrics system by specifying a named pipe or a file for the metrics output.

  ## Request Body

  **Content Types**: `application/json`

  Metrics system description
  """
  @spec put_metrics(body :: Hyper.Firecracker.Api.Metrics.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_metrics(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_metrics},
      url: "/metrics",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.Metrics, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Creates a MMDS (Microvm Metadata Service) data store.

  ## Request Body

  **Content Types**: `application/json`

  The MMDS data store as JSON.
  """
  @spec put_mmds(body :: map, opts :: keyword) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_mmds(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_mmds},
      url: "/mmds",
      body: body,
      method: :put,
      request: [{"application/json", :map}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Set MMDS configuration. Pre-boot only.

  Configures MMDS version, IPv4 address used by the MMDS network stack and interfaces that allow MMDS requests.

  ## Request Body

  **Content Types**: `application/json`

  The MMDS configuration as JSON.
  """
  @spec put_mmds_config(body :: Hyper.Firecracker.Api.MmdsConfig.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_mmds_config(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_mmds_config},
      url: "/mmds/config",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.MmdsConfig, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Configures the serial console

  Configure the serial console, which the guest can write its kernel logs to. Has no effect if the serial console is not also enabled on the guest kernel command line

  ## Request Body

  **Content Types**: `application/json`

  Serial console properties
  """
  @spec put_serial_device(body :: Hyper.Firecracker.Api.SerialDevice.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def put_serial_device(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :put_serial_device},
      url: "/serial",
      body: body,
      method: :put,
      request: [{"application/json", {Hyper.Firecracker.Api.SerialDevice, :t}}],
      response: [{204, :null}, default: {Hyper.Firecracker.Api.Error, :t}],
      opts: opts
    })
  end

  @doc """
  Starts a free page hinting run only if enabled pre-boot.

  ## Request Body

  **Content Types**: `application/json`

  When the device completes the hinting whether we should automatically ack this.
  """
  @spec start_balloon_hinting(body :: Hyper.Firecracker.Api.BalloonStartCmd.t(), opts :: keyword) ::
          :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def start_balloon_hinting(body, opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [body: body],
      call: {Hyper.Firecracker.Api.Operations, :start_balloon_hinting},
      url: "/balloon/hinting/start",
      body: body,
      method: :patch,
      request: [{"application/json", {Hyper.Firecracker.Api.BalloonStartCmd, :t}}],
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end

  @doc """
  Stops a free page hinting run only if enabled pre-boot.
  """
  @spec stop_balloon_hinting(opts :: keyword) :: :ok | {:error, Hyper.Firecracker.Api.Error.t()}
  def stop_balloon_hinting(opts \\ []) do
    client = opts[:client] || @default_client

    client.request(%{
      args: [],
      call: {Hyper.Firecracker.Api.Operations, :stop_balloon_hinting},
      url: "/balloon/hinting/stop",
      method: :patch,
      response: [
        {204, :null},
        {400, {Hyper.Firecracker.Api.Error, :t}},
        default: {Hyper.Firecracker.Api.Error, :t}
      ],
      opts: opts
    })
  end
end
