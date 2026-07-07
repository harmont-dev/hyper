defmodule Sys.Linux.Cgroup.V2.CpuStat do
  @moduledoc """
  Reads a cgroup v2 `cpu.stat` interface file — the cumulative CPU time the
  cgroup's processes have actually executed since the cgroup was created.

  `usage_usec` only advances while a process in the cgroup is on-CPU, so an
  idle cgroup's counter stands still: it measures compute *performed*, not
  compute allocated. A single reading is meaningless on its own; consumption
  over a window is the delta between two readings (see
  `Hyper.Node.FireVMM.Meter`).

  Laws under test: a rendered payload round-trips `usage_usec`/`user_usec`/
  `system_usec` regardless of line order or unknown lines; a payload without
  `usage_usec` is always refused.
  """

  alias Unit.Time

  @enforce_keys [:usage]
  defstruct [:usage, user: Time.zero(), system: Time.zero()]

  @type t :: %__MODULE__{usage: Time.t(), user: Time.t(), system: Time.t()}

  @doc "Read and parse `<cgroup_dir>/cpu.stat`."
  @spec read(Path.t()) :: {:ok, t()} | {:error, File.posix() | :missing_usage}
  def read(cgroup_dir) do
    with {:ok, content} <- File.read(Path.join(cgroup_dir, "cpu.stat")) do
      parse(content)
    end
  end

  @doc """
  Parse a `cpu.stat` payload. Refuses a payload without a well-formed
  `usage_usec` — the billing counter must never silently read as zero.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :missing_usage}
  def parse(content) do
    fields =
      content
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split/1)
      |> Enum.reduce(%{}, &absorb/2)

    case fields do
      %{"usage_usec" => usage} ->
        {:ok,
         %__MODULE__{
           usage: usage,
           user: Map.get(fields, "user_usec", Time.zero()),
           system: Map.get(fields, "system_usec", Time.zero())
         }}

      _missing ->
        {:error, :missing_usage}
    end
  end

  @spec absorb([String.t()], %{String.t() => Time.t()}) :: %{String.t() => Time.t()}
  defp absorb([key, value], acc) when key in ~w(usage_usec user_usec system_usec) do
    case Integer.parse(value) do
      {usec, ""} when usec >= 0 -> Map.put(acc, key, Time.us(usec))
      _malformed -> acc
    end
  end

  defp absorb(_line, acc), do: acc
end
