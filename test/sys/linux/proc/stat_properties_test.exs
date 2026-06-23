defmodule Sys.Linux.Proc.StatPropertiesTest do
  @moduledoc """
  Generative round-trip for `/proc/stat`: build a syntactically valid file from
  random counters, parse it, and assert every value survived. Also pins the
  `CpuTimes` arithmetic (total = sum of all ten states; idle = idle + iowait) and
  the kernel-compat rule that missing trailing columns default to zero.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Proc.Stat
  alias Sys.Linux.Proc.Stat.CpuTimes

  defp counter, do: integer(0..1_000_000_000)
  # A full 10-column CPU line's worth of jiffies.
  defp cpu_cols, do: list_of(counter(), length: 10)
  defp cpu_line(prefix, cols), do: Enum.join([prefix | Enum.map(cols, &Integer.to_string/1)], " ")

  property "CpuTimes.from_columns round-trips all ten state counters" do
    check all(cols <- cpu_cols()) do
      t = CpuTimes.from_columns(cols)

      assert [
               t.user,
               t.nice,
               t.system,
               t.idle,
               t.iowait,
               t.irq,
               t.softirq,
               t.steal,
               t.guest,
               t.guest_nice
             ] == cols
    end
  end

  property "total is the sum of all states and idle is idle + iowait" do
    check all(cols <- cpu_cols()) do
      t = CpuTimes.from_columns(cols)
      assert CpuTimes.total(t) == Enum.sum(cols)
      assert CpuTimes.idle(t) == Enum.at(cols, 3) + Enum.at(cols, 4)
    end
  end

  property "missing trailing columns default to zero (older-kernel compatibility)" do
    check all(n <- integer(3..10), cols <- list_of(counter(), length: n)) do
      t = CpuTimes.from_columns(cols)

      present = [
        t.user,
        t.nice,
        t.system,
        t.idle,
        t.iowait,
        t.irq,
        t.softirq,
        t.steal,
        t.guest,
        t.guest_nice
      ]

      assert Enum.take(present, n) == cols
      assert Enum.drop(present, n) |> Enum.all?(&(&1 == 0))
    end
  end

  property "a synthesized /proc/stat round-trips the aggregate, per-core, and scalar fields" do
    check all(
            agg <- cpu_cols(),
            cores <- list_of(cpu_cols(), min_length: 1, max_length: 8),
            ctxt <- counter(),
            btime <- counter(),
            processes <- counter(),
            running <- counter(),
            blocked <- counter()
          ) do
      core_lines =
        cores
        |> Enum.with_index()
        |> Enum.map(fn {cols, i} -> cpu_line("cpu#{i}", cols) end)

      content =
        ([cpu_line("cpu", agg)] ++
           core_lines ++
           [
             # An intr line with a long body the parser must skip regardless of length.
             "intr 999 1 2 3 4 5 6 7 8 9 10 11 12",
             "ctxt #{ctxt}",
             "btime #{btime}",
             "processes #{processes}",
             "procs_running #{running}",
             "procs_blocked #{blocked}",
             "softirq 123 4 5 6 7"
           ])
        |> Enum.join("\n")

      snap = Stat.parse(content)

      assert CpuTimes.total(snap.cpu) == Enum.sum(agg)
      assert length(snap.cpus) == length(cores)
      assert Enum.map(snap.cpus, &CpuTimes.total/1) == Enum.map(cores, &Enum.sum/1)
      assert snap.ctxt == ctxt
      assert snap.btime == btime
      assert snap.processes == processes
      assert snap.procs_running == running
      assert snap.procs_blocked == blocked
    end
  end
end
