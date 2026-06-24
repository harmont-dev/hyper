defmodule Hyper.SuidHelper.DmsetupPropertiesTest do
  @moduledoc """
  Pins the device-mapper table grammar produced by the pure builders: a table
  always begins at sector 0, names the right target, and places every field in
  its kernel-mandated position. A reordered or mis-positioned field would map
  the wrong device, so each property splits the table back into fields and
  asserts positions. Also covers `parse_targets/1` round-trip.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.SuidHelper.Dmsetup

  # A device path / token with no whitespace (whitespace is the field separator).
  defp dev, do: string([?a..?z, ?A..?Z, ?0..?9, ?/, ?-, ?_, ?.], min_length: 1, max_length: 16)
  defp pos, do: integer(1..1_000_000_000)
  defp nonneg, do: integer(0..1_000_000_000)

  property "snapshot_table places origin, cow, persistent flag, and chunk in order" do
    check all(origin <- dev(), cow <- dev(), sectors <- pos(), chunk <- pos()) do
      table = Dmsetup.snapshot_table(origin, cow, sectors, chunk)

      assert ["0", s, "snapshot", o, c, "P", ch] = String.split(table)
      assert s == "#{sectors}"
      assert o == origin
      assert c == cow
      assert ch == "#{chunk}"
    end
  end

  property "thin_pool_table places meta, data, block size, and low water in order" do
    check all(meta <- dev(), data <- dev(), sectors <- pos(), block <- pos(), low <- nonneg()) do
      table = Dmsetup.thin_pool_table(meta, data, sectors, block, low)

      assert ["0", s, "thin-pool", m, d, b, w] = String.split(table)
      assert s == "#{sectors}"
      assert m == meta
      assert d == data
      assert b == "#{block}"
      assert w == "#{low}"
    end
  end

  property "thin_external_table places pool, dev_id, and origin in order" do
    check all(pool <- dev(), dev_id <- nonneg(), sectors <- pos(), origin <- dev()) do
      table = Dmsetup.thin_external_table(pool, dev_id, sectors, origin)

      assert ["0", s, "thin", p, id, o] = String.split(table)
      assert s == "#{sectors}"
      assert p == pool
      assert id == "#{dev_id}"
      assert o == origin
    end
  end

  property "every table starts at logical sector 0 and a positive length" do
    check all(origin <- dev(), cow <- dev(), sectors <- pos(), chunk <- pos()) do
      table = Dmsetup.snapshot_table(origin, cow, sectors, chunk)
      assert ["0", len | _] = String.split(table)
      assert String.to_integer(len) == sectors
      assert sectors > 0
    end
  end

  property "parse_targets recovers the first column of each non-blank line" do
    check all(targets <- uniq_list_of(dev(), min_length: 1, max_length: 6)) do
      # Render each as a `dmsetup targets` row: "<name> vM.m.p" plus blank lines.
      out =
        targets
        |> Enum.map_join("\n", fn t -> "#{t}        v1.2.3" end)
        |> Kernel.<>("\n\n")

      assert Dmsetup.parse_targets(out) == MapSet.new(targets)
    end
  end
end
