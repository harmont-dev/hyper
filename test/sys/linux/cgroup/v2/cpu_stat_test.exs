defmodule Sys.Linux.Cgroup.V2.CpuStatTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Cgroup.V2.CpuStat
  alias Unit.Time

  # A real cpu.stat from a cgroup with cpu.max set (kernel 6.8).
  @real_cpu_stat """
  usage_usec 8451289
  user_usec 5321004
  system_usec 3130285
  core_sched.force_idle_usec 0
  nr_periods 84052
  nr_throttled 113
  throttled_usec 921034
  nr_bursts 0
  burst_usec 0
  """

  test "parses a real cpu.stat payload" do
    assert {:ok, %CpuStat{usage: usage, user: user, system: system}} =
             CpuStat.parse(@real_cpu_stat)

    assert Time.as_us(usage) == 8_451_289
    assert Time.as_us(user) == 5_321_004
    assert Time.as_us(system) == 3_130_285
  end

  test "user/system default to zero when absent (cpu controller stats only)" do
    assert {:ok, %CpuStat{user: user, system: system}} = CpuStat.parse("usage_usec 42\n")
    assert Time.as_us(user) == 0
    assert Time.as_us(system) == 0
  end

  test "a malformed value line is skipped, not misread" do
    assert {:ok, %CpuStat{usage: usage}} =
             CpuStat.parse("user_usec garbage\nusage_usec 7\n")

    assert Time.as_us(usage) == 7
  end

  @tag :tmp_dir
  test "read/1 reads <dir>/cpu.stat", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "cpu.stat"), "usage_usec 1234\n")
    assert {:ok, %CpuStat{usage: usage}} = CpuStat.read(dir)
    assert Time.as_us(usage) == 1_234
  end

  @tag :tmp_dir
  test "read/1 surfaces a missing file as a posix error", %{tmp_dir: dir} do
    assert {:error, :enoent} = CpuStat.read(dir)
  end
end
