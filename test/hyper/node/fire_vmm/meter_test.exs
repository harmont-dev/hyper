defmodule Hyper.Node.FireVMM.MeterTest do
  @moduledoc """
  Example tests for the meter's billing contract: the reading at meter start
  is the baseline (never billed); every counter advance observed after it —
  including one that fits entirely inside a single sample interval — is
  flushed exactly once; empty windows are dropped without a write and logged.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Hyper.Node.FireVMM.Meter
  alias Unit.Time

  @moduletag :tmp_dir
  @moduletag :capture_log

  defp write_cpu_stat(dir, usec) do
    File.write!(Path.join(dir, "cpu.stat"), "usage_usec #{usec}\nnr_periods 1\n")
  end

  defp start_meter(dir, vm_id \\ "vmetertest") do
    parent = self()

    opts = %Meter.Opts{
      vm_id: vm_id,
      cgroup_dir: dir,
      sink: fn attrs ->
        send(parent, {:usage, attrs})
        :ok
      end,
      register?: false
    }

    start_supervised!({Meter, opts})
  end

  test "accrues deltas across samples and flushes one window", %{tmp_dir: dir} do
    write_cpu_stat(dir, 1_000)
    meter = start_meter(dir)

    :ok = Meter.sample_now(meter)
    write_cpu_stat(dir, 5_000)
    :ok = Meter.sample_now(meter)
    :ok = Meter.flush_now(meter)

    assert_receive {:usage, %{vm_id: "vmetertest", cpu_time: cpu} = attrs}
    assert Time.as_us(cpu) == 4_000
    assert DateTime.compare(attrs.window_start, attrs.window_end) in [:lt, :eq]
  end

  test "a counter reset (recreated cgroup) accrues the new reading, never negative",
       %{tmp_dir: dir} do
    write_cpu_stat(dir, 1_000)
    meter = start_meter(dir)
    :ok = Meter.sample_now(meter)

    write_cpu_stat(dir, 5_000)
    :ok = Meter.sample_now(meter)

    # cgroup torn down and recreated: counter restarts near zero.
    write_cpu_stat(dir, 300)
    :ok = Meter.sample_now(meter)
    :ok = Meter.flush_now(meter)

    assert_receive {:usage, %{cpu_time: cpu}}
    assert Time.as_us(cpu) == 4_000 + 300
  end

  test "a zero-consumption window is not recorded", %{tmp_dir: dir} do
    write_cpu_stat(dir, 1_000)
    meter = start_meter(dir)

    :ok = Meter.sample_now(meter)
    :ok = Meter.sample_now(meter)
    :ok = Meter.flush_now(meter)

    refute_receive {:usage, _attrs}, 100
  end

  test "an unreadable cgroup is skipped, then metering resumes", %{tmp_dir: dir} do
    meter = start_meter(dir)

    # No cpu.stat yet (jailer still creating the leaf): samples are skipped.
    :ok = Meter.sample_now(meter)

    write_cpu_stat(dir, 2_000)
    :ok = Meter.sample_now(meter)
    write_cpu_stat(dir, 2_500)
    :ok = Meter.sample_now(meter)
    :ok = Meter.flush_now(meter)

    assert_receive {:usage, %{cpu_time: cpu}}
    assert Time.as_us(cpu) == 500
  end

  test "a failed flush keeps the accrued time and the next flush retries",
       %{tmp_dir: dir} do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> :fail end)

    opts = %Meter.Opts{
      vm_id: "vmetertest",
      cgroup_dir: dir,
      sink: fn attrs ->
        case Agent.get(agent, & &1) do
          :fail ->
            {:error, :db_down}

          :ok ->
            send(parent, {:usage, attrs})
            :ok
        end
      end,
      register?: false
    }

    meter = start_supervised!({Meter, opts})

    write_cpu_stat(dir, 100)
    :ok = Meter.sample_now(meter)
    write_cpu_stat(dir, 700)
    :ok = Meter.sample_now(meter)
    :ok = Meter.flush_now(meter)
    refute_receive {:usage, _attrs}, 100

    Agent.update(agent, fn _state -> :ok end)
    :ok = Meter.flush_now(meter)
    assert_receive {:usage, %{cpu_time: cpu}}
    assert Time.as_us(cpu) == 600
  end

  test "dropping an empty window before any usage was recorded warns with the sample counters",
       %{tmp_dir: dir} do
    write_cpu_stat(dir, 1_000)
    meter = start_meter(dir, "vmeterwarn")

    # The counter never advances after init's start-of-life baseline sample,
    # so the window is legitimately empty — but a VM that has never recorded
    # any usage is operator-visible, hence the warning.
    log = capture_log(fn -> :ok = Meter.flush_now(meter) end)

    refute_receive {:usage, _attrs}, 100
    assert log =~ "[warning]"
    assert log =~ "vm vmeterwarn: dropping empty usage window with no usage ever recorded"
    assert log =~ "1 ok/0 failed cgroup samples"
    assert log =~ "0 recorded/0 dropped windows"

    # Only the FIRST never-recorded drop warns: a long-lived never-active VM
    # would otherwise repeat the warning every window for its whole life.
    warnings = capture_log([level: :warning], fn -> :ok = Meter.flush_now(meter) end)
    refute warnings =~ "vm vmeterwarn"

    debug = capture_log(fn -> :ok = Meter.flush_now(meter) end)
    assert debug =~ "vm vmeterwarn: dropping empty usage window"
    assert debug =~ "0 recorded/2 dropped windows"
  end

  test "the empty-window warning carries the failed-sample count and last error",
       %{tmp_dir: dir} do
    meter = start_meter(dir, "vmetererr")

    # No cpu.stat at all: every read fails (init's baseline attempt included),
    # nothing ever accrues. The baseline retry keeps sampling concurrently, so
    # assert the counter's shape rather than an exact count.
    :ok = Meter.sample_now(meter)
    log = capture_log(fn -> :ok = Meter.flush_now(meter) end)

    assert log =~ "vm vmetererr: dropping empty usage window with no usage ever recorded"
    assert log =~ ~r"0 ok/\d+ failed cgroup samples"
    assert log =~ "last sample error: :enoent"
  end

  test "an idle window after usage has been recorded drops at debug, not warning",
       %{tmp_dir: dir} do
    write_cpu_stat(dir, 1_000)
    meter = start_meter(dir, "vmeteridle")

    :ok = Meter.sample_now(meter)
    write_cpu_stat(dir, 5_000)
    :ok = Meter.sample_now(meter)
    :ok = Meter.flush_now(meter)
    assert_receive {:usage, _attrs}

    warnings = capture_log([level: :warning], fn -> :ok = Meter.flush_now(meter) end)
    refute warnings =~ "vm vmeteridle"

    debug = capture_log(fn -> :ok = Meter.flush_now(meter) end)
    assert debug =~ "vm vmeteridle: dropping empty usage window"
    assert debug =~ "1 recorded/1 dropped windows"
  end

  test "a life shorter than one sample interval still bills the burn since meter start",
       %{tmp_dir: dir} do
    write_cpu_stat(dir, 1_000)
    meter = start_meter(dir)

    # No sample_now and no time for a periodic tick: the meter's whole life
    # fits inside one sample interval — the CI zero-row flake. init's baseline
    # plus terminate's final sample must bill the advance anyway.
    write_cpu_stat(dir, 43_210)
    :ok = stop_supervised(Meter)
    refute Process.alive?(meter)

    assert_receive {:usage, %{cpu_time: cpu}}
    assert Time.as_us(cpu) == 42_210
  end

  test "a leaf that appears after meter start is baselined well within one sample interval",
       %{tmp_dir: dir} do
    meter = start_meter(dir)

    # The jailer creates the cgroup leaf asynchronously after the meter
    # starts. The baseline retry must observe it much faster than the 1s
    # sample interval — the bound fails if the meter waits a full interval.
    write_cpu_stat(dir, 2_000)
    assert poll_until(fn -> :sys.get_state(meter).samples_ok >= 1 end, 900)

    write_cpu_stat(dir, 2_750)
    :ok = stop_supervised(Meter)

    assert_receive {:usage, %{cpu_time: cpu}}
    assert Time.as_us(cpu) == 750
  end

  defp poll_until(fun, timeout_ms) do
    poll_until_deadline(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll_until_deadline(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(10)
        poll_until_deadline(fun, deadline)
    end
  end

  test "terminate takes a final sample and flushes the tail", %{tmp_dir: dir} do
    write_cpu_stat(dir, 1_000)
    meter = start_meter(dir)
    :ok = Meter.sample_now(meter)

    # Consumption after the last periodic sample must still be billed.
    write_cpu_stat(dir, 9_000)
    :ok = stop_supervised(Meter)
    refute Process.alive?(meter)

    assert_receive {:usage, %{cpu_time: cpu}}
    assert Time.as_us(cpu) == 8_000
  end
end
