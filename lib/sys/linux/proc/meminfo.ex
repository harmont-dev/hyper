defmodule Sys.Linux.Proc.Meminfo do
  @moduledoc """
  Reads memory totals from `/proc/meminfo`.

  `MemAvailable` is the kernel's own estimate of memory obtainable for a new
  workload without swapping - the right figure for "how loaded is this node",
  preferable to `MemFree` (which ignores reclaimable cache). Values in the file
  are kibibytes; they are returned as `Unit.Information`.
  """

  alias Unit.Information

  @path "/proc/meminfo"

  defmodule Snapshot do
    @moduledoc "Total and kernel-available memory at one instant."
    @type t :: %__MODULE__{total: Information.t(), available: Information.t()}
    @enforce_keys [:total, :available]
    defstruct [:total, :available]
  end

  @doc "Read and parse `/proc/meminfo`."
  @spec read() :: {:ok, Snapshot.t()} | {:error, File.posix()}
  def read do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc "Parse a `/proc/meminfo` payload."
  @spec parse(String.t()) :: Snapshot.t()
  def parse(content) do
    kib = field_map(content)

    %Snapshot{
      total: Information.kib(Map.fetch!(kib, "MemTotal")),
      available: Information.kib(Map.fetch!(kib, "MemAvailable"))
    }
  end

  # Build %{"MemTotal" => 16384, ...} from "Key: <n> kB" lines.
  @spec field_map(String.t()) :: %{String.t() => non_neg_integer()}
  defp field_map(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line) do
        [key, value | _rest] -> [{String.trim_trailing(key, ":"), String.to_integer(value)}]
        _ -> []
      end
    end)
    |> Map.new()
  end
end
