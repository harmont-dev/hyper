defmodule Hyper.Node.FireVMM.MeterPropertiesTest do
  @moduledoc """
  Law under test: over one meter incarnation, the flushed total is exactly
  `final counter value - counter value at meter start`, for any monotone
  sequence of counter advances. The reading at meter start is the baseline
  and is never billed; everything the counter advances after it is billed
  exactly once by the teardown flush, no matter how the advances interleave
  with samples — so metering can never over-count, and (with the init-time
  baseline) never silently drops a life that burned CPU.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.FireVMM.Meter
  alias Unit.Time

  @moduletag :tmp_dir
  @moduletag :capture_log

  property "terminate bills exactly the counter advance since meter start",
           %{tmp_dir: dir} do
    check all(
            initial <- integer(0..50_000),
            increments <- list_of(integer(1..10_000), min_length: 1, max_length: 8)
          ) do
      write_cpu_stat(dir, initial)

      parent = self()

      opts = %Meter.Opts{
        vm_id: "vmeterprop",
        cgroup_dir: dir,
        sink: fn attrs ->
          send(parent, {:usage, attrs})
          :ok
        end,
        register?: false
      }

      {:ok, meter} = Meter.start_link(opts)

      final =
        Enum.reduce(increments, initial, fn increment, value ->
          advanced = value + increment
          write_cpu_stat(dir, advanced)
          :ok = Meter.sample_now(meter)
          advanced
        end)

      :ok = GenServer.stop(meter)

      assert_receive {:usage, %{cpu_time: cpu}}
      assert Time.as_us(cpu) == final - initial
    end
  end

  defp write_cpu_stat(dir, usec) do
    File.write!(Path.join(dir, "cpu.stat"), "usage_usec #{usec}\nnr_periods 1\n")
  end
end
