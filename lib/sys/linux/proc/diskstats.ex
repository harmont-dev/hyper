defmodule Sys.Linux.Proc.Diskstats do
  @moduledoc """
  Reads cumulative block-device I/O from `/proc/diskstats`.

  Per line the fields after `major minor name` are `reads_completed reads_merged
  sectors_read ... writes_completed writes_merged sectors_written ...`. A sector is
  512 bytes. Whole-disk counters already include their partitions' I/O, so
  `total_physical/1` counts whole physical disks only - summing partitions too
  would double-count, and virtual devices (`loop`, `dm-`, `ram`, `md`, ...) are not
  real node bandwidth.
  """

  @path "/proc/diskstats"
  @sector_bytes 512

  # sectors_read and sectors_written, 0-based among whitespace-split tokens.
  @sectors_read_idx 5
  @sectors_written_idx 9

  @virtual_prefix ~r/^(loop|ram|zram|sr|fd|md|dm-)/
  @nvme_mmc_partition ~r/^(nvme\d+n\d+|mmcblk\d+)p\d+$/
  @scsi_partition ~r/^(sd|vd|hd|xvd)[a-z]+\d+$/

  defmodule Device do
    @moduledoc "One `/proc/diskstats` row: a block device and its cumulative (read + written) bytes."
    @type t :: %__MODULE__{name: String.t(), bytes: non_neg_integer()}
    @enforce_keys [:name, :bytes]
    defstruct [:name, :bytes]
  end

  @doc "Read `/proc/diskstats` and total the bytes across whole physical disks."
  @spec read_total_physical() :: {:ok, non_neg_integer()} | {:error, File.posix()}
  def read_total_physical do
    with {:ok, content} <- File.read(@path), do: {:ok, total_physical(content)}
  end

  @doc "Parse each `/proc/diskstats` row into a `Device` with its cumulative (read + written) bytes."
  @spec parse(String.t()) :: [Device.t()]
  def parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_major, _minor, name | _rest] = fields when length(fields) > @sectors_written_idx ->
          read = String.to_integer(Enum.at(fields, @sectors_read_idx))
          written = String.to_integer(Enum.at(fields, @sectors_written_idx))
          [%Device{name: name, bytes: (read + written) * @sector_bytes}]

        _ ->
          []
      end
    end)
  end

  @doc "Whether `name` is a whole physical disk (not a partition or virtual device)."
  @spec physical_device?(String.t()) :: boolean()
  def physical_device?(name) do
    not Regex.match?(@virtual_prefix, name) and
      not Regex.match?(@nvme_mmc_partition, name) and
      not Regex.match?(@scsi_partition, name)
  end

  @doc "Total cumulative bytes across whole physical disks."
  @spec total_physical(String.t()) :: non_neg_integer()
  def total_physical(content) do
    content
    |> parse()
    |> Enum.filter(fn %Device{name: name} -> physical_device?(name) end)
    |> Enum.map(fn %Device{bytes: bytes} -> bytes end)
    |> Enum.sum()
  end
end
