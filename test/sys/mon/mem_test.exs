defmodule Sys.Mon.MemTest do
  @moduledoc """
  Contract of `Sys.Mon.Mem.used/1`: used memory is `MemTotal - MemAvailable`.

  The property is a constructed-inverse oracle - build a snapshot whose total is
  a known used figure above the available figure, and `used/1` must recover that
  figure exactly. The example pins the deliberately-unclamped edge: a nonsensical
  `available > total` surfaces as a negative figure rather than being hidden.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Proc.Meminfo.Snapshot
  alias Sys.Mon.Mem
  alias Unit.Information

  defp snapshot(total_bytes, available_bytes) do
    %Snapshot{
      total: Information.bytes(total_bytes),
      available: Information.bytes(available_bytes),
      free: Information.bytes(0),
      buffers: Information.bytes(0),
      cached: Information.bytes(0)
    }
  end

  property "used recovers the total-minus-available gap it was built from" do
    check all(
            used <- integer(0..1_000_000_000_000),
            available <- integer(0..1_000_000_000_000)
          ) do
      snap = snapshot(used + available, available)
      assert Information.as_bytes(Mem.used(snap)) == used
    end
  end

  test "an impossible available > total surfaces as a negative figure (unclamped)" do
    assert Information.as_bytes(Mem.used(snapshot(100, 150))) == -50
  end
end
