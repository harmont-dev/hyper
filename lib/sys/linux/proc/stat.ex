defmodule Sys.Linux.Proc.Stat do
  @moduledoc """
  Reads kernel counters from `/proc/stat`.

  Captures the aggregate `cpu` line, the per-core `cpuN` lines, and the scalar
  counters (`ctxt`, `btime`, `processes`, `procs_running`, `procs_blocked`). The
  `intr` and `softirq` lines are intentionally skipped: their bodies are long,
  hardware-specific per-source vectors that carry no portable meaning.

  CPU figures are cumulative jiffies since boot, so a single read is meaningless on
  its own; utilization is a busy fraction the caller derives from the delta between
  two snapshots (see `Sys.Mon.Cpu`).
  """

  @path "/proc/stat"

  defmodule CpuTimes do
    @moduledoc """
    Cumulative jiffies a CPU (the aggregate, or one core) has spent in each state
    since boot: `user nice system idle iowait irq softirq steal guest guest_nice`.

    The trailing fields were added across kernel versions (`iowait`/`irq`/`softirq`
    in 2.6, `steal` in 2.6.11, `guest` in 2.6.24, `guest_nice` in 2.6.33); any
    column absent on an older kernel defaults to `0`.
    """
    @type t :: %__MODULE__{
            user: non_neg_integer(),
            nice: non_neg_integer(),
            system: non_neg_integer(),
            idle: non_neg_integer(),
            iowait: non_neg_integer(),
            irq: non_neg_integer(),
            softirq: non_neg_integer(),
            steal: non_neg_integer(),
            guest: non_neg_integer(),
            guest_nice: non_neg_integer()
          }
    defstruct user: 0,
              nice: 0,
              system: 0,
              idle: 0,
              iowait: 0,
              irq: 0,
              softirq: 0,
              steal: 0,
              guest: 0,
              guest_nice: 0

    @columns ~w(user nice system idle iowait irq softirq steal guest guest_nice)a

    @doc """
    Build from the integer columns of a `cpu`/`cpuN` line. Missing trailing
    columns default to `0`; any beyond `guest_nice` are ignored.
    """
    @spec from_columns([non_neg_integer()]) :: t()
    def from_columns(values) do
      struct!(__MODULE__, Enum.zip(@columns, values))
    end

    @doc "Total jiffies across every state - the denominator of a utilization ratio."
    @spec total(t()) :: non_neg_integer()
    def total(%__MODULE__{} = times) do
      times |> Map.from_struct() |> Map.values() |> Enum.sum()
    end

    @doc "Jiffies spent not doing work: `idle + iowait`."
    @spec idle(t()) :: non_neg_integer()
    def idle(%__MODULE__{idle: idle, iowait: iowait}), do: idle + iowait
  end

  defmodule Snapshot do
    @moduledoc "A point-in-time `/proc/stat` reading."
    @type t :: %__MODULE__{
            cpu: CpuTimes.t(),
            cpus: [CpuTimes.t()],
            ctxt: non_neg_integer(),
            btime: non_neg_integer(),
            processes: non_neg_integer(),
            procs_running: non_neg_integer(),
            procs_blocked: non_neg_integer()
          }
    @enforce_keys [:cpu, :cpus, :ctxt, :btime, :processes, :procs_running, :procs_blocked]
    defstruct [:cpu, :cpus, :ctxt, :btime, :processes, :procs_running, :procs_blocked]
  end

  @doc "Read and parse `/proc/stat`."
  @spec read() :: {:ok, Snapshot.t()} | {:error, File.posix()}
  def read do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc "Parse a `/proc/stat` payload."
  @spec parse(String.t()) :: Snapshot.t()
  def parse(content) do
    rows =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)

    %Snapshot{
      cpu: aggregate_cpu(rows),
      cpus: per_core_cpus(rows),
      ctxt: scalar(rows, "ctxt"),
      btime: scalar(rows, "btime"),
      processes: scalar(rows, "processes"),
      procs_running: scalar(rows, "procs_running"),
      procs_blocked: scalar(rows, "procs_blocked")
    }
  end

  # The aggregate line whose key is exactly "cpu" (not "cpuN").
  @spec aggregate_cpu([[String.t()]]) :: CpuTimes.t()
  defp aggregate_cpu(rows) do
    ["cpu" | columns] = Enum.find(rows, &match?(["cpu" | _], &1))
    CpuTimes.from_columns(integers(columns))
  end

  # The per-core "cpuN" lines, in file order (core 0, 1, ...).
  @spec per_core_cpus([[String.t()]]) :: [CpuTimes.t()]
  defp per_core_cpus(rows) do
    rows
    |> Enum.filter(fn [key | _] -> key =~ ~r/^cpu\d+$/ end)
    |> Enum.map(fn [_key | columns] -> CpuTimes.from_columns(integers(columns)) end)
  end

  # A single-value counter line (`<key> <int>`); 0 if the key is absent.
  @spec scalar([[String.t()]], String.t()) :: non_neg_integer()
  defp scalar(rows, key) do
    case Enum.find(rows, &match?([^key | _], &1)) do
      [^key, value | _] -> String.to_integer(value)
      _ -> 0
    end
  end

  @spec integers([String.t()]) :: [non_neg_integer()]
  defp integers(columns), do: Enum.map(columns, &String.to_integer/1)
end
