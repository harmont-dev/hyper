defmodule Sys.Linux.Proc.StatTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.Stat
  alias Sys.Linux.Proc.Stat.CpuTimes
  alias Sys.Linux.Proc.Stat.Snapshot

  # A real `/proc/stat` from a 4-core x86-64 host. The `intr` and `softirq` lines
  # are trimmed (their real bodies are hundreds of hardware-specific columns) - the
  # parser must skip them regardless of length, so a short stand-in is sufficient.
  @real_stat """
  cpu  82839544 24829 11800385 2274752391 869487 0 572097 28706 0 0
  cpu0 20576683 5896 2983120 568705807 221680 0 238935 8430 0 0
  cpu1 20876500 6637 2903285 568613252 209473 0 182507 7417 0 0
  cpu2 20669722 6513 3000023 568646701 227533 0 82326 6652 0 0
  cpu3 20716638 5782 2913955 568786630 210800 0 68327 6206 0 0
  intr 11338214003 157 9 0 0 0 0 0 0 0 0 0 0 15
  ctxt 21444949116
  btime 1775978134
  processes 52877251
  procs_running 1
  procs_blocked 0
  softirq 2699659170 1636 319210240 127982 230548910 3684320 0
  """

  describe "parse/1" do
    test "parses the aggregate cpu line into a full CpuTimes breakdown" do
      snap = Stat.parse(@real_stat)

      assert snap.cpu == %CpuTimes{
               user: 82_839_544,
               nice: 24_829,
               system: 11_800_385,
               idle: 2_274_752_391,
               iowait: 869_487,
               irq: 0,
               softirq: 572_097,
               steal: 28_706,
               guest: 0,
               guest_nice: 0
             }
    end

    test "parses every per-core cpuN line in order" do
      snap = Stat.parse(@real_stat)

      assert length(snap.cpus) == 4

      assert List.first(snap.cpus) == %CpuTimes{
               user: 20_576_683,
               nice: 5_896,
               system: 2_983_120,
               idle: 568_705_807,
               iowait: 221_680,
               irq: 0,
               softirq: 238_935,
               steal: 8_430,
               guest: 0,
               guest_nice: 0
             }

      assert Enum.at(snap.cpus, 3).user == 20_716_638
      assert Enum.at(snap.cpus, 3).idle == 568_786_630
    end

    test "parses the scalar counters and skips intr/softirq bodies" do
      snap = Stat.parse(@real_stat)

      assert snap.ctxt == 21_444_949_116
      assert snap.btime == 1_775_978_134
      assert snap.processes == 52_877_251
      assert snap.procs_running == 1
      assert snap.procs_blocked == 0
    end

    test "the aggregate excludes the per-core lines (cpu, not cpuN)" do
      snap = Stat.parse(@real_stat)

      # The aggregate is its own line; summing cores would be a different number.
      refute snap.cpu in snap.cpus
    end

    test "defaults missing scalar counters to 0" do
      snap = Stat.parse("cpu  1 2 3 4 0 0 0 0 0 0\n")

      assert snap.cpus == []
      assert snap.ctxt == 0
      assert snap.procs_blocked == 0
    end
  end

  describe "CpuTimes" do
    test "total/1 sums every state; idle/1 folds in iowait" do
      snap = Stat.parse(@real_stat)

      assert CpuTimes.idle(snap.cpu) == 2_274_752_391 + 869_487

      assert CpuTimes.total(snap.cpu) ==
               82_839_544 + 24_829 + 11_800_385 + 2_274_752_391 + 869_487 +
                 572_097 + 28_706
    end

    test "from_columns/1 tolerates older kernels with fewer columns" do
      # Pre-2.6 style: only user/nice/system/idle present.
      times = CpuTimes.from_columns([10, 20, 30, 40])

      assert times == %CpuTimes{user: 10, nice: 20, system: 30, idle: 40}
      assert CpuTimes.total(times) == 100
      assert CpuTimes.idle(times) == 40
    end

    test "from_columns/1 ignores columns beyond guest_nice" do
      times = CpuTimes.from_columns([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])

      assert times.guest_nice == 10
      assert CpuTimes.total(times) == Enum.sum(1..10)
    end
  end

  describe "read/0" do
    test "reads and parses the live /proc/stat into a sane Snapshot" do
      assert {:ok, %Snapshot{} = snap} = Stat.read()

      assert %CpuTimes{} = snap.cpu
      assert CpuTimes.total(snap.cpu) > 0
      assert snap.cpus != []
      assert snap.btime > 0
    end
  end
end
