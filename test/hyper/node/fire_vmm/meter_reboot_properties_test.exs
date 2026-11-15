defmodule Hyper.Node.FireVMM.MeterRebootPropertiesTest do
  @moduledoc """
  Reboot billing (#134): the Daemon's teardown protocol — a last bounded
  `sample_now/2` whose failure is swallowed, the cgroup leaf removed, then
  `rebase/1` — followed by a fresh leaf born at zero.

  Laws:

    * over any interleaving of guest CPU burn, reboots, samples and flushes,
      the usage the meter records equals the CPU burned after the meter
      started — reboots neither drop nor re-bill a microsecond;
    * metering never over-counts, even when the meter is busy (a slow usage
      INSERT) while the VM reboots, so the Daemon's last sample times out and
      the meter only reads the counter after the new leaf exists.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.FireVMM.Meter
  alias Unit.Time

  @moduletag :tmp_dir
  @moduletag :capture_log

  @last_sample_ms 250

  defp event do
    one_of([
      tuple({constant(:burn), integer(1..1_000_000)}),
      constant(:reboot),
      constant(:sample),
      constant(:flush)
    ])
  end

  property "recorded usage equals the burn since meter start, across any reboots",
           %{tmp_dir: tmp} do
    check all(baseline <- integer(0..1_000_000), events <- list_of(event(), max_length: 25)) do
      dir = Path.join(tmp, "leaf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      write_cpu_stat(dir, baseline)
      meter = start_meter(dir)

      {_counter, burned} =
        Enum.reduce(events, {baseline, 0}, fn
          {:burn, n}, {counter, burned} ->
            write_cpu_stat(dir, counter + n)
            {counter + n, burned + n}

          :reboot, {_counter, burned} ->
            daemon_teardown(meter, dir)
            write_cpu_stat(dir, 0)
            {0, burned}

          :sample, acc ->
            :ok = Meter.sample_now(meter)
            acc

          :flush, acc ->
            :ok = Meter.flush_now(meter)
            acc
        end)

      :ok = GenServer.stop(meter)

      assert recorded_us() == burned
    end
  end

  test "a reboot while the meter is busy flushing never bills the new leaf twice",
       %{tmp_dir: dir} do
    test = self()

    slow_first_insert = fn attrs ->
      send(test, {:usage, Time.as_us(attrs.cpu_time)})

      if Process.put(:inserted_before, true) == nil do
        receive do
          :insert_committed -> :ok
        end
      end

      :ok
    end

    write_cpu_stat(dir, 0)
    meter = start_meter(dir, slow_first_insert)
    write_cpu_stat(dir, 10_000)
    :ok = Meter.sample_now(meter)

    flushing = Task.async(fn -> Meter.flush_now(meter) end)
    assert_receive {:usage, 10_000}

    daemon_teardown(meter, dir)
    write_cpu_stat(dir, 3_000)
    send(meter, :insert_committed)
    :ok = Task.await(flushing)

    write_cpu_stat(dir, 5_000)
    :ok = GenServer.stop(meter)

    billed = recorded_us()

    assert billed <= 5_000,
           "the new leaf burned 5000us after the reboot, but the meter billed #{billed}us"
  end

  defp daemon_teardown(meter, dir) do
    _ =
      try do
        Meter.sample_now(meter, @last_sample_ms)
      catch
        :exit, _ -> :no_meter
      end

    File.rm!(Path.join(dir, "cpu.stat"))
    :ok = Meter.rebase(meter)
  end

  defp start_meter(dir, sink \\ nil) do
    test = self()

    sink =
      sink ||
        fn attrs ->
          send(test, {:usage, Time.as_us(attrs.cpu_time)})
          :ok
        end

    {:ok, meter} =
      Meter.start_link(%Meter.Opts{
        vm_id: "vmeterreboot",
        cgroup_dir: dir,
        sink: sink,
        register?: false
      })

    Process.unlink(meter)
    meter
  end

  defp recorded_us(acc \\ 0) do
    receive do
      {:usage, us} -> recorded_us(acc + us)
    after
      0 -> acc
    end
  end

  defp write_cpu_stat(dir, usec) do
    File.write!(Path.join(dir, "cpu.stat"), "usage_usec #{usec}\nnr_periods 1\n")
  end
end
