defmodule Hyper.Node.Budget.HardStatePropertiesTest do
  @moduledoc """
  Algebraic laws of the pure `Hyper.Node.Budget.Hard.State` accumulator: `cut`
  is the inverse of `bump` on every spec, bumps accumulate additively (so the
  running total is order-independent), and `track`/`untrack` round-trip a
  reservation by reference. The example tests spot-check single values; these
  pin the laws across the domain.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Node.Budget.Hard.State
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  # Only `mem`/`disk` matter to bump/cut; the other fields are along for the ride.
  defp spec do
    gen all(mem_mib <- integer(0..1_000_000), disk_mib <- integer(0..1_000_000)) do
      %Spec{
        vcpus: 1,
        mem: Information.mib(mem_mib),
        disk: Information.mib(disk_mib),
        disk_bw: Bandwidth.zero(),
        net_bw: Bandwidth.zero()
      }
    end
  end

  property "cut undoes bump for any spec" do
    check all(s <- spec()) do
      state = State.zero() |> State.bump(s) |> State.cut(s)
      assert state.mem_allocated == Information.zero()
      assert state.disk_allocated == Information.zero()
    end
  end

  property "the running total is the sum of bumped specs (hence order-independent)" do
    check all(specs <- list_of(spec(), max_length: 20)) do
      state = Enum.reduce(specs, State.zero(), fn s, acc -> State.bump(acc, s) end)

      total_mem = specs |> Enum.map(&Information.as_bytes(&1.mem)) |> Enum.sum()
      total_disk = specs |> Enum.map(&Information.as_bytes(&1.disk)) |> Enum.sum()

      assert Information.as_bytes(state.mem_allocated) == total_mem
      assert Information.as_bytes(state.disk_allocated) == total_disk
    end
  end

  property "untrack returns exactly the spec track stored, leaving the rest unchanged" do
    check all(s <- spec()) do
      base = State.zero()
      ref = make_ref()
      tracked = State.track(base, ref, s)
      assert {^s, rest} = State.untrack(tracked, ref)
      assert rest.reservations == base.reservations
    end
  end

  property "untrack of a ref that was never tracked yields nil and an unchanged state" do
    check all(s <- spec()) do
      ref = make_ref()
      other = make_ref()
      state = State.track(State.zero(), ref, s)
      assert {nil, ^state} = State.untrack(state, other)
    end
  end
end
