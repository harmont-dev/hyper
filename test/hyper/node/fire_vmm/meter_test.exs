defmodule Hyper.Node.FireVMM.MeterTest do
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

    # A single successful sample is only the accumulator's baseline: the CI
    # zero-row scenario, where the VM died within the first sample interval.
    :ok = Meter.sample_now(meter)
    log = capture_log(fn -> :ok = Meter.flush_now(meter) end)

    refute_receive {:usage, _attrs}, 100
    assert log =~ "[warning]"
    assert log =~ "vm vmeterwarn: dropping empty usage window with no usage ever recorded"
    assert log =~ "1 ok/0 failed cgroup samples"
    assert log =~ "0 recorded/0 dropped windows"
  end

  test "the empty-window warning carries the failed-sample count and last error",
       %{tmp_dir: dir} do
    meter = start_meter(dir, "vmetererr")

    # No cpu.stat at all: every read fails, nothing ever accrues.
    :ok = Meter.sample_now(meter)
    :ok = Meter.sample_now(meter)
    log = capture_log(fn -> :ok = Meter.flush_now(meter) end)

    assert log =~ "vm vmetererr: dropping empty usage window with no usage ever recorded"
    assert log =~ "0 ok/2 failed cgroup samples"
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
