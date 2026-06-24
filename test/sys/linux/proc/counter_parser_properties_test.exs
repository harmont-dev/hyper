defmodule Sys.Linux.Proc.CounterParserPropertiesTest do
  @moduledoc """
  Generative round-trips for the three counter-oriented /proc parsers. Each builds
  a syntactically valid file from random counters and asserts the parser recovers
  them, applies the right column offsets and unit conversions, and drops the header
  and malformed rows.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Proc.{Diskstats, Meminfo, NetDev}
  alias Unit.Information

  defp big, do: integer(0..1_000_000_000_000)
  # An interface/device name: lowercase letters/digits, optionally with a `:alias`.
  defp ifname do
    gen all(
          base <- string([?a..?z, ?0..?9], min_length: 1, max_length: 6),
          alias_suffix <- one_of([constant(""), map(integer(0..9), &":#{&1}")])
        ) do
      base <> alias_suffix
    end
  end

  describe "NetDev.parse/1" do
    property "round-trips rx (col 0) and tx (col 8), keeps alias names, drops headers" do
      check all(
              rows <-
                uniq_list_of(
                  gen(
                    all name <- ifname(), counters <- list_of(big(), length: 16) do
                      {name, counters}
                    end
                  ),
                  uniq_fun: fn {n, _} -> n end,
                  min_length: 1,
                  max_length: 6
                )
            ) do
        body =
          Enum.map_join(rows, "\n", fn {name, c} ->
            "  #{name}: " <> Enum.map_join(c, " ", &Integer.to_string/1)
          end)

        content = "Inter-|   Receive ...\n face |bytes ... |bytes ...\n" <> body
        parsed = NetDev.parse(content)

        assert length(parsed) == length(rows)

        for {name, c} <- rows do
          iface = Enum.find(parsed, &(&1.name == name))
          assert iface.rx_bytes == Enum.at(c, 0)
          assert iface.tx_bytes == Enum.at(c, 8)
        end
      end
    end
  end

  describe "Diskstats.parse/1" do
    property "converts sectors (idx 5/9) to bytes via x512 and round-trips names" do
      check all(
              rows <-
                uniq_list_of(
                  gen(
                    all name <- ifname(),
                        major <- integer(0..259),
                        minor <- integer(0..255),
                        stats <- list_of(big(), length: 14) do
                      {name, major, minor, stats}
                    end
                  ),
                  uniq_fun: fn {n, _, _, _} -> n end,
                  min_length: 1,
                  max_length: 6
                )
            ) do
        body =
          Enum.map_join(rows, "\n", fn {name, maj, min, stats} ->
            "  #{maj}  #{min} #{name} " <> Enum.map_join(stats, " ", &Integer.to_string/1)
          end)

        parsed = Diskstats.parse(body)
        assert length(parsed) == length(rows)

        for {name, _maj, _min, stats} <- rows do
          dev = Enum.find(parsed, &(&1.name == name))
          assert dev.read_bytes == Enum.at(stats, 2) * 512
          assert dev.write_bytes == Enum.at(stats, 6) * 512
        end
      end
    end
  end

  describe "Meminfo.parse/1" do
    property "wraps each kB value as Information (bytes = kB x 1024)" do
      check all(total <- big(), avail <- big(), free <- big(), buffers <- big(), cached <- big()) do
        content = """
        MemTotal:       #{total} kB
        MemFree:        #{free} kB
        MemAvailable:   #{avail} kB
        Buffers:        #{buffers} kB
        Cached:         #{cached} kB
        SwapTotal:      0 kB
        """

        snap = Meminfo.parse(content)
        assert Information.as_bytes(snap.total) == total * 1024
        assert Information.as_bytes(snap.available) == avail * 1024
        assert Information.as_bytes(snap.free) == free * 1024
        assert Information.as_bytes(snap.buffers) == buffers * 1024
        assert Information.as_bytes(snap.cached) == cached * 1024
      end
    end
  end
end
