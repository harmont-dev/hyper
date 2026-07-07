defmodule Hyper.Node.FireVMM.MeterTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Meter
  alias Unit.Time

  @moduletag :tmp_dir

  defp write_cpu_stat(dir, usec) do
    File.write!(Path.join(dir, "cpu.stat"), "usage_usec #{usec}\nnr_periods 1\n")
  end

  defp start_meter(dir) do
    parent = self()

    opts = %Meter.Opts{
      vm_id: "vmetertest",
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
