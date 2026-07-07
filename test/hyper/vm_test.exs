defmodule Hyper.VmTest do
  @moduledoc """
  Contract of the fork fallback triage: exactly the node-admission refusals
  (and the scheduler's aggregate `:no_capacity`) send `fork/1` down the
  publish-and-reschedule path; everything else — unknown VM, unreachable node,
  I/O faults — must surface to the caller, because retrying placement cannot
  fix it.
  """
  use ExUnit.Case, async: true

  alias Hyper.Vm

  test "admission refusals trigger the slow-fork fallback" do
    for reason <- [
          :no_capacity,
          :exhausted,
          :cpu_saturated,
          :disk_bw_saturated,
          :net_bw_saturated,
          :mem_exhausted,
          :disk_exhausted
        ] do
      assert Vm.capacity_error?(reason), "#{inspect(reason)} must fall back"
    end
  end

  test "faults are surfaced, never masked by a re-placement" do
    for reason <- [
          :not_found,
          :node_unreachable,
          {:parent_mutable_not_found, "v123"},
          {:record_failed, :blob, :boom},
          {:firecracker_exited, 137}
        ] do
      refute Vm.capacity_error?(reason), "#{inspect(reason)} must surface"
    end
  end
end
