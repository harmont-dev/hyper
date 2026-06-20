defmodule Hyper.Node.FireVMM.Client.Schema do
  @moduledoc """
  Request/response model structs for the Firecracker v1.16.0 API, mirroring the
  `definitions` in `priv/firecracker/firecracker-v1.16.0.yaml`. These are pure
  data: required spec fields use `@enforce_keys`, optional fields default to
  `nil` and are dropped at encode time by `Hyper.Node.FireVMM.Client.Body`.
  """

  defmodule TokenBucket do
    @moduledoc "Token bucket for rate limiting (bytes or ops)."
    @enforce_keys [:size, :refill_time]
    defstruct [:size, :refill_time, :one_time_burst]

    @type t :: %__MODULE__{
            size: non_neg_integer(),
            refill_time: non_neg_integer(),
            one_time_burst: non_neg_integer() | nil
          }
  end

  defmodule RateLimiter do
    @moduledoc "IO rate limiter with independent bandwidth/ops buckets."
    defstruct [:bandwidth, :ops]
    @type t :: %__MODULE__{bandwidth: TokenBucket.t() | nil, ops: TokenBucket.t() | nil}
  end

  defmodule BootSource do
    @moduledoc "Boot source descriptor."
    @enforce_keys [:kernel_image_path]
    defstruct [:kernel_image_path, :boot_args, :initrd_path]

    @type t :: %__MODULE__{
            kernel_image_path: String.t(),
            boot_args: String.t() | nil,
            initrd_path: String.t() | nil
          }
  end

  defmodule Drive do
    @moduledoc "Block device descriptor (virtio-block or vhost-user-block)."
    @enforce_keys [:drive_id, :is_root_device]
    defstruct [
      :drive_id,
      :is_root_device,
      :partuuid,
      :cache_type,
      :is_read_only,
      :path_on_host,
      :rate_limiter,
      :io_engine,
      :socket
    ]

    @type t :: %__MODULE__{
            drive_id: String.t(),
            is_root_device: boolean(),
            partuuid: String.t() | nil,
            cache_type: String.t() | nil,
            is_read_only: boolean() | nil,
            path_on_host: String.t() | nil,
            rate_limiter: RateLimiter.t() | nil,
            io_engine: String.t() | nil,
            socket: String.t() | nil
          }
  end

  defmodule PartialDrive do
    @moduledoc "Partial drive update (post-boot)."
    @enforce_keys [:drive_id]
    defstruct [:drive_id, :path_on_host, :rate_limiter]

    @type t :: %__MODULE__{
            drive_id: String.t(),
            path_on_host: String.t() | nil,
            rate_limiter: RateLimiter.t() | nil
          }
  end

  defmodule MachineConfiguration do
    @moduledoc "vCPU/memory/SMT/huge-page/CPU-template config."
    @enforce_keys [:vcpu_count, :mem_size_mib]
    defstruct [:vcpu_count, :mem_size_mib, :smt, :cpu_template, :track_dirty_pages, :huge_pages]

    @type t :: %__MODULE__{
            vcpu_count: pos_integer(),
            mem_size_mib: pos_integer(),
            smt: boolean() | nil,
            cpu_template: String.t() | nil,
            track_dirty_pages: boolean() | nil,
            huge_pages: String.t() | nil
          }
  end

  defmodule NetworkInterface do
    @moduledoc "Network interface descriptor."
    @enforce_keys [:iface_id, :host_dev_name]
    defstruct [:iface_id, :host_dev_name, :guest_mac, :mtu, :rx_rate_limiter, :tx_rate_limiter]

    @type t :: %__MODULE__{
            iface_id: String.t(),
            host_dev_name: String.t(),
            guest_mac: String.t() | nil,
            mtu: pos_integer() | nil,
            rx_rate_limiter: RateLimiter.t() | nil,
            tx_rate_limiter: RateLimiter.t() | nil
          }
  end

  defmodule PartialNetworkInterface do
    @moduledoc "Partial network interface update (rate limiters, post-boot)."
    @enforce_keys [:iface_id]
    defstruct [:iface_id, :rx_rate_limiter, :tx_rate_limiter]

    @type t :: %__MODULE__{
            iface_id: String.t(),
            rx_rate_limiter: RateLimiter.t() | nil,
            tx_rate_limiter: RateLimiter.t() | nil
          }
  end

  defmodule InstanceActionInfo do
    @moduledoc "Action to perform: FlushMetrics | InstanceStart | SendCtrlAltDel."
    @enforce_keys [:action_type]
    defstruct [:action_type]
    @type t :: %__MODULE__{action_type: String.t()}
  end

  defmodule Vm do
    @moduledoc "MicroVM running state: Paused | Resumed (used to pause/resume)."
    @enforce_keys [:state]
    defstruct [:state]
    @type t :: %__MODULE__{state: String.t()}
  end

  defmodule Logger do
    @moduledoc "Logging configuration."
    defstruct [:level, :log_path, :show_level, :show_log_origin, :module]

    @type t :: %__MODULE__{
            level: String.t() | nil,
            log_path: String.t() | nil,
            show_level: boolean() | nil,
            show_log_origin: boolean() | nil,
            module: String.t() | nil
          }
  end

  defmodule Metrics do
    @moduledoc "Metrics sink configuration."
    @enforce_keys [:metrics_path]
    defstruct [:metrics_path]
    @type t :: %__MODULE__{metrics_path: String.t()}
  end

  defmodule MmdsConfig do
    @moduledoc "MMDS (metadata service) configuration."
    @enforce_keys [:network_interfaces]
    defstruct [:network_interfaces, :version, :ipv4_address, :imds_compat]

    @type t :: %__MODULE__{
            network_interfaces: [String.t()],
            version: String.t() | nil,
            ipv4_address: String.t() | nil,
            imds_compat: boolean() | nil
          }
  end

  defmodule Vsock do
    @moduledoc "Vsock device descriptor."
    @enforce_keys [:guest_cid, :uds_path]
    defstruct [:guest_cid, :uds_path, :vsock_id]

    @type t :: %__MODULE__{
            guest_cid: pos_integer(),
            uds_path: String.t(),
            vsock_id: String.t() | nil
          }
  end

  defmodule EntropyDevice do
    @moduledoc "Entropy (virtio-rng) device."
    defstruct [:rate_limiter]
    @type t :: %__MODULE__{rate_limiter: RateLimiter.t() | nil}
  end

  defmodule SerialDevice do
    @moduledoc "Serial console configuration."
    defstruct [:serial_out_path, :rate_limiter]
    @type t :: %__MODULE__{serial_out_path: String.t() | nil, rate_limiter: TokenBucket.t() | nil}
  end

  defmodule Balloon do
    @moduledoc "Memory balloon device descriptor."
    @enforce_keys [:amount_mib, :deflate_on_oom]
    defstruct [
      :amount_mib,
      :deflate_on_oom,
      :stats_polling_interval_s,
      :free_page_hinting,
      :free_page_reporting
    ]

    @type t :: %__MODULE__{
            amount_mib: non_neg_integer(),
            deflate_on_oom: boolean(),
            stats_polling_interval_s: non_neg_integer() | nil,
            free_page_hinting: boolean() | nil,
            free_page_reporting: boolean() | nil
          }
  end

  defmodule BalloonUpdate do
    @moduledoc "Balloon target-size update (post-boot)."
    @enforce_keys [:amount_mib]
    defstruct [:amount_mib]
    @type t :: %__MODULE__{amount_mib: non_neg_integer()}
  end

  defmodule BalloonStatsUpdate do
    @moduledoc "Balloon statistics polling interval update."
    @enforce_keys [:stats_polling_interval_s]
    defstruct [:stats_polling_interval_s]
    @type t :: %__MODULE__{stats_polling_interval_s: non_neg_integer()}
  end

  defmodule BalloonStartCmd do
    @moduledoc "Start a free-page-hinting run."
    defstruct [:acknowledge_on_stop]
    @type t :: %__MODULE__{acknowledge_on_stop: boolean() | nil}
  end

  defmodule CpuConfig do
    @moduledoc "CPU configuration template (bitmap modifiers). Fields are arch-specific arrays; modeled as loose maps/lists since callers supply raw modifier maps."
    defstruct [
      :kvm_capabilities,
      :cpuid_modifiers,
      :msr_modifiers,
      :reg_modifiers,
      :vcpu_features
    ]

    @type t :: %__MODULE__{
            kvm_capabilities: [String.t()] | nil,
            cpuid_modifiers: [map()] | nil,
            msr_modifiers: [map()] | nil,
            reg_modifiers: [map()] | nil,
            vcpu_features: [map()] | nil
          }
  end

  defmodule Pmem do
    @moduledoc "Persistent-memory (virtio-pmem) device."
    @enforce_keys [:id, :path_on_host]
    defstruct [:id, :path_on_host, :root_device, :read_only, :rate_limiter]

    @type t :: %__MODULE__{
            id: String.t(),
            path_on_host: String.t(),
            root_device: boolean() | nil,
            read_only: boolean() | nil,
            rate_limiter: RateLimiter.t() | nil
          }
  end

  defmodule PartialPmem do
    @moduledoc "Partial pmem update (rate limiter, post-boot)."
    @enforce_keys [:id]
    defstruct [:id, :rate_limiter]
    @type t :: %__MODULE__{id: String.t(), rate_limiter: RateLimiter.t() | nil}
  end

  defmodule MemoryBackend do
    @moduledoc "Snapshot memory backend (File | Uffd)."
    @enforce_keys [:backend_type, :backend_path]
    defstruct [:backend_type, :backend_path]
    @type t :: %__MODULE__{backend_type: String.t(), backend_path: String.t()}
  end

  defmodule SnapshotCreateParams do
    @moduledoc "Parameters for creating a snapshot."
    @enforce_keys [:mem_file_path, :snapshot_path]
    defstruct [:mem_file_path, :snapshot_path, :snapshot_type]

    @type t :: %__MODULE__{
            mem_file_path: String.t(),
            snapshot_path: String.t(),
            snapshot_type: String.t() | nil
          }
  end

  defmodule NetworkOverride do
    @moduledoc "TAP device override on snapshot restore."
    @enforce_keys [:iface_id, :host_dev_name]
    defstruct [:iface_id, :host_dev_name]
    @type t :: %__MODULE__{iface_id: String.t(), host_dev_name: String.t()}
  end

  defmodule VsockOverride do
    @moduledoc "Vsock UDS path override on snapshot restore."
    @enforce_keys [:uds_path]
    defstruct [:uds_path]
    @type t :: %__MODULE__{uds_path: String.t()}
  end

  defmodule SnapshotLoadParams do
    @moduledoc "Parameters for loading a snapshot. Exactly one of mem_file_path/mem_backend."
    @enforce_keys [:snapshot_path]
    defstruct [
      :snapshot_path,
      :mem_file_path,
      :mem_backend,
      :enable_diff_snapshots,
      :track_dirty_pages,
      :resume_vm,
      :network_overrides,
      :vsock_override,
      :clock_realtime
    ]

    @type t :: %__MODULE__{
            snapshot_path: String.t(),
            mem_file_path: String.t() | nil,
            mem_backend: MemoryBackend.t() | nil,
            enable_diff_snapshots: boolean() | nil,
            track_dirty_pages: boolean() | nil,
            resume_vm: boolean() | nil,
            network_overrides: [NetworkOverride.t()] | nil,
            vsock_override: VsockOverride.t() | nil,
            clock_realtime: boolean() | nil
          }
  end

  defmodule MemoryHotplugConfig do
    @moduledoc "virtio-mem hotpluggable memory configuration."
    defstruct [:total_size_mib, :slot_size_mib, :block_size_mib]

    @type t :: %__MODULE__{
            total_size_mib: non_neg_integer() | nil,
            slot_size_mib: non_neg_integer() | nil,
            block_size_mib: non_neg_integer() | nil
          }
  end

  defmodule MemoryHotplugSizeUpdate do
    @moduledoc "Hotplug memory size update."
    defstruct [:requested_size_mib]
    @type t :: %__MODULE__{requested_size_mib: non_neg_integer() | nil}
  end
end
