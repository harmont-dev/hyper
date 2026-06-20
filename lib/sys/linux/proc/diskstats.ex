defmodule Sys.Linux.Proc.Diskstats do
  @moduledoc """
  Parses `/proc/diskstats` into per-device I/O counters.

  Each line is `major minor name <stats...>`. This reads the cumulative sector
  counts (`sectors_read`, column 6; `sectors_written`, column 10) and converts them
  to bytes - a sector is 512 bytes by kernel convention, independent of the disk's
  physical sector size.

  Every device line is returned as-is: whole disks, partitions, and loop/dm/nbd
  virtual devices alike. Which devices count toward a metric (and how to avoid
  double-counting a disk and its partitions) is the caller's policy, not this
  parser's concern.
  """

  @path "/proc/diskstats"
  @sector_bytes 512

  # 0-based offsets among the whitespace-split tokens of a line.
  @sectors_read_idx 5
  @sectors_written_idx 9

  defmodule Device do
    @moduledoc "One `/proc/diskstats` row: a block device and its cumulative read/written bytes."
    @type t :: %__MODULE__{
            name: String.t(),
            read_bytes: non_neg_integer(),
            write_bytes: non_neg_integer()
          }
    @enforce_keys [:name, :read_bytes, :write_bytes]
    defstruct [:name, :read_bytes, :write_bytes]
  end

  @doc "Read and parse `/proc/diskstats`."
  @spec read() :: {:ok, [Device.t()]} | {:error, File.posix()}
  def read do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc "Parse a `/proc/diskstats` payload into one `Device` per device line."
  @spec parse(String.t()) :: [Device.t()]
  def parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [_major, _minor, name | _rest] = fields when length(fields) > @sectors_written_idx ->
          [
            %Device{
              name: name,
              read_bytes: column(fields, @sectors_read_idx) * @sector_bytes,
              write_bytes: column(fields, @sectors_written_idx) * @sector_bytes
            }
          ]

        _ ->
          []
      end
    end)
  end

  @spec column([String.t()], non_neg_integer()) :: non_neg_integer()
  defp column(fields, idx), do: fields |> Enum.at(idx) |> String.to_integer()
end
