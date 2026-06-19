defmodule Sys.Linux.Proc.Stat do
  @moduledoc """
  Reads aggregate CPU time counters from `/proc/stat`.

  The first line (`cpu  …`) holds cumulative jiffies since boot across all cores:
  `user nice system idle iowait irq softirq steal guest guest_nice`. A single read
  is meaningless on its own — CPU *utilization* is the busy fraction between two
  snapshots (see `utilization/2`). `idle` here folds in `iowait`, the conventional
  "not doing work" bucket.
  """

  @path "/proc/stat"

  defmodule Snapshot do
    @moduledoc "Cumulative idle and total CPU jiffies at one instant."
    @type t :: %__MODULE__{idle: non_neg_integer(), total: non_neg_integer()}
    @enforce_keys [:idle, :total]
    defstruct [:idle, :total]
  end

  @doc "Read and parse `/proc/stat`."
  @spec read() :: {:ok, Snapshot.t()} | {:error, File.posix()}
  def read do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc "Parse the aggregate `cpu` line of a `/proc/stat` payload."
  @spec parse(String.t()) :: Snapshot.t()
  def parse(content) do
    ["cpu" | fields] =
      content
      |> String.split("\n", parts: 2)
      |> hd()
      |> String.split()

    nums = Enum.map(fields, &String.to_integer/1)
    [_user, _nice, _system, idle, iowait | _rest] = nums

    %Snapshot{idle: idle + iowait, total: Enum.sum(nums)}
  end

  @doc """
  CPU utilization (busy fraction, `0.0..1.0`) between an earlier and a later
  snapshot. A non-positive interval yields `0.0`.
  """
  @spec utilization(Snapshot.t(), Snapshot.t()) :: float()
  def utilization(%Snapshot{idle: i0, total: t0}, %Snapshot{idle: i1, total: t1}) do
    dt = t1 - t0
    di = i1 - i0

    if dt <= 0 do
      0.0
    else
      ((dt - di) / dt)
      |> max(0.0)
      |> min(1.0)
    end
  end
end
