defmodule Sys.Mon.DiskBw do
  @behaviour Sys.Mon.Sampler

  alias Controls.Rate
  alias Sys.Linux.Proc.Diskstats
  alias Sys.Mon.Server
  alias Unit.Bandwidth

  @moduledoc """
  Monitors instantaneous disk bandwidth (the soft beta_disk_bw signal).

  Samples cumulative read+write bytes across whole physical disks from
  `/proc/diskstats` every 31 ms and differentiates them into bytes/sec
  via `Controls.Rate` (the first read only establishes a baseline). The rate series
  is smoothed with a 20-second time constant. Readings are `Unit.Bandwidth`.
  """

  # Prime sampling period, co-prime with the sibling monitors so their reads
  # rarely land on the same tick.
  @impl true
  @spec period :: Unit.Time.t()
  def period, do: Unit.Time.ms(31)

  @impl true
  @spec tau :: Unit.Time.t()
  def tau, do: Unit.Time.s(20)

  @doc "The latest instantaneous + filtered disk bandwidth (`Unit.Bandwidth` readings)."
  @spec value() :: Server.Reading.t()
  def value, do: Server.value(__MODULE__)

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: %{id: __MODULE__, start: {Server, :start_link, [__MODULE__]}}

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(rate_state) do
    case Diskstats.read() do
      {:ok, devices} ->
        rate_state
        |> Rate.compute(physical_bytes(devices), System.monotonic_time(:millisecond))
        |> as_bandwidth()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Sum read+write bytes across physical whole disks only. A physical disk exposes
  # a backing device at /sys/block/<dev>/device; loop/dm/nbd/ram/md virtual devices
  # do not, and partitions are not top-level under /sys/block at all - so this is
  # the kernel's own distinction, needing no device-name patterns. Excluding
  # partitions also avoids double-counting: a whole disk's counters already include
  # its partitions' I/O.
  @spec physical_bytes([Diskstats.Device.t()]) :: non_neg_integer()
  defp physical_bytes(devices) do
    devices
    |> Enum.filter(&physical?(&1.name))
    |> sum_bytes()
  end

  @spec physical?(String.t()) :: boolean()
  defp physical?(name), do: File.exists?("/sys/block/#{name}/device")

  @doc false
  # Total read+write bytes across the given devices. Pure: the physical-device
  # filtering happens upstream, so this is exactly the cumulative-counter
  # denominator handed to `Rate`.
  @spec sum_bytes([Diskstats.Device.t()]) :: non_neg_integer()
  def sum_bytes(devices) do
    Enum.reduce(devices, 0, fn d, acc -> acc + d.read_bytes + d.write_bytes end)
  end

  @doc false
  # Project the raw bytes/sec rate into a `Unit.Bandwidth` reading; `:skip`
  # (no baseline yet) passes through untouched.
  @spec as_bandwidth({:ok, float(), Rate.state()} | {:skip, Rate.state()}) ::
          {:ok, Bandwidth.t(), Rate.state()} | {:skip, Rate.state()}
  def as_bandwidth({:ok, bytes_per_sec, state}),
    do: {:ok, Bandwidth.bps(round(bytes_per_sec)), state}

  def as_bandwidth({:skip, state}), do: {:skip, state}
end
