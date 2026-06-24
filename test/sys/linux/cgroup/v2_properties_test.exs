defmodule Sys.Linux.Cgroup.V2PropertiesTest do
  @moduledoc """
  Invariants of the pure cgroup-v2 config builder and its `as_linux/1` renderer:
  each setter is reflected in exactly its interface file, the rendered strings
  match the kernel's `cpu.max`/`memory.max` formats, and an empty config renders
  to an empty map.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Sys.Linux.Cgroup.V2.Config

  defp pos, do: integer(1..1_000_000_000)

  property "an empty config renders to an empty map" do
    assert Config.as_linux(Config.new()) == %{}
  end

  property "cpu_max renders quota and period under the cpu.max key" do
    check all(quota <- pos(), period <- pos()) do
      linux = Config.new() |> Config.cpu_max(quota, period) |> Config.as_linux()
      assert linux == %{"cpu.max": "#{quota} #{period}"}
    end
  end

  property "memory_max renders as the byte string under :\"memory.max\"" do
    check all(bytes <- pos()) do
      linux = Config.new() |> Config.memory_max(bytes) |> Config.as_linux()
      assert linux == %{"memory.max": "#{bytes}"}
    end
  end

  property "both limits render independently, regardless of set order" do
    check all(quota <- pos(), period <- pos(), bytes <- pos()) do
      a = Config.new() |> Config.cpu_max(quota, period) |> Config.memory_max(bytes)
      b = Config.new() |> Config.memory_max(bytes) |> Config.cpu_max(quota, period)

      expected = %{"cpu.max": "#{quota} #{period}", "memory.max": "#{bytes}"}
      assert Config.as_linux(a) == expected
      assert Config.as_linux(b) == expected
    end
  end

  property "the last write to a key wins" do
    check all(q1 <- pos(), p1 <- pos(), q2 <- pos(), p2 <- pos()) do
      linux =
        Config.new()
        |> Config.cpu_max(q1, p1)
        |> Config.cpu_max(q2, p2)
        |> Config.as_linux()

      assert linux == %{"cpu.max": "#{q2} #{p2}"}
    end
  end

  property "the last memory_max write wins" do
    check all(b1 <- pos(), b2 <- pos()) do
      linux = Config.new() |> Config.memory_max(b1) |> Config.memory_max(b2) |> Config.as_linux()
      assert linux == %{"memory.max": "#{b2}"}
    end
  end
end
