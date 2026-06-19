defmodule Sys.Mon.Rate do
  @moduledoc """
  Turns a monotonically increasing byte counter (e.g. `/proc/diskstats` sectors
  or `/proc/net/dev` bytes) into a per-second rate.

  The first observation has no baseline, and a reboot resets the counter
  backwards; both cases return `:skip` (carrying the new baseline) rather than a
  meaningless or negative rate. `mono_ms` must come from `System.monotonic_time/1`.
  """

  @type state :: {non_neg_integer(), integer()} | nil

  @doc """
  Given the previous `state`, the latest cumulative `count`, and the monotonic
  timestamp `mono_ms` of this reading, return the rate in counter-units per
  second together with the new state.
  """
  @spec compute(state(), non_neg_integer(), integer()) ::
          {:ok, float(), state()} | {:skip, state()}
  def compute(nil, count, mono_ms), do: {:skip, {count, mono_ms}}

  def compute({prev_count, _prev_mono}, count, mono_ms) when count < prev_count do
    {:skip, {count, mono_ms}}
  end

  def compute({prev_count, prev_mono}, count, mono_ms) do
    dt = mono_ms - prev_mono

    if dt <= 0 do
      {:skip, {count, mono_ms}}
    else
      {:ok, (count - prev_count) * 1000.0 / dt, {count, mono_ms}}
    end
  end
end
