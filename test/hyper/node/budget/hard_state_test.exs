defmodule Hyper.Node.Budget.HardStateTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Budget.Hard.State
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  defp spec(mem_mib, disk_mib) do
    %Spec{
      vcpus: 1,
      mem: Information.mib(mem_mib),
      disk: Information.mib(disk_mib),
      disk_bw: Bandwidth.zero(),
      net_bw: Bandwidth.zero()
    }
  end

  test "zero starts with no allocation and no reservations" do
    s = State.zero()
    assert s.mem_allocated == Information.zero()
    assert s.disk_allocated == Information.zero()
    assert s.reservations == %{}
  end

  test "bump then cut of the same spec round-trips to zero" do
    sp = spec(512, 1024)
    state = State.zero() |> State.bump(sp) |> State.cut(sp)
    assert state.mem_allocated == Information.zero()
    assert state.disk_allocated == Information.zero()
  end

  test "bump accumulates memory and disk across specs" do
    state = State.zero() |> State.bump(spec(512, 1024)) |> State.bump(spec(256, 512))
    assert state.mem_allocated == Information.mib(768)
    assert state.disk_allocated == Information.mib(1536)
  end

  test "track then untrack returns the owned spec and drops the ref" do
    ref = make_ref()
    sp = spec(128, 256)
    state = State.zero() |> State.track(ref, sp)
    assert {^sp, rest} = State.untrack(state, ref)
    assert rest.reservations == %{}
  end

  test "untrack of an unknown ref yields nil and leaves the state unchanged" do
    state = State.zero()
    assert {nil, ^state} = State.untrack(state, make_ref())
  end
end
