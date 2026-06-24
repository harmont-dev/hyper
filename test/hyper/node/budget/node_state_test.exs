defmodule Hyper.Node.Budget.NodeStateTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  # A node with generous headroom, idle on every metric. Override per case.
  defp roomy_state(overrides \\ %{}) do
    struct!(
      %NodeState{
        node: :node@host,
        mem_free: Information.gib(8),
        disk_free: Information.gib(100),
        cpu_load: 0.0,
        cpu_capacity: 8,
        cpu_max_load: 0.8,
        disk_bw_load: Bandwidth.zero(),
        disk_bw_ceiling: Bandwidth.gibps(1),
        net_bw_load: Bandwidth.zero(),
        net_bw_ceiling: Bandwidth.gibps(1),
        layers: []
      },
      overrides
    )
  end

  defp spec(overrides \\ %{}) do
    struct!(
      %Spec{
        vcpus: 1,
        mem: Information.gib(1),
        disk: Information.gib(10),
        disk_bw: Bandwidth.mibps(10),
        net_bw: Bandwidth.mibps(10)
      },
      overrides
    )
  end

  test "a spec that fits every metric is admitted" do
    assert NodeState.fits?(roomy_state(), spec())
  end

  test "memory demand over free headroom is rejected" do
    state = roomy_state(%{mem_free: Information.gib(1)})
    refute NodeState.fits?(state, spec(%{mem: Information.gib(2)}))
  end

  test "memory demand exactly at free headroom still fits (<= boundary)" do
    state = roomy_state(%{mem_free: Information.gib(2)})
    assert NodeState.fits?(state, spec(%{mem: Information.gib(2)}))
  end

  test "disk demand over free headroom is rejected" do
    state = roomy_state(%{disk_free: Information.gib(5)})
    refute NodeState.fits?(state, spec(%{disk: Information.gib(6)}))
  end

  test "cpu demand that crosses the load ceiling is rejected" do
    # load 0.5 + 3 vcpus / 8 cores = 0.875 > cpu_max_load 0.8
    state = roomy_state(%{cpu_load: 0.5})
    refute NodeState.fits?(state, spec(%{vcpus: 3}))
  end

  test "cpu demand exactly at the load ceiling still fits" do
    # load 0.0 + 8 vcpus / 8 cores = 1.0 <= cpu_max_load 1.0
    state = roomy_state(%{cpu_max_load: 1.0})
    assert NodeState.fits?(state, spec(%{vcpus: 8}))
  end

  test "disk bandwidth over its ceiling is rejected" do
    state = roomy_state(%{disk_bw_ceiling: Bandwidth.mibps(5)})
    refute NodeState.fits?(state, spec(%{disk_bw: Bandwidth.mibps(6)}))
  end

  test "net bandwidth over its ceiling is rejected" do
    state = roomy_state(%{net_bw_ceiling: Bandwidth.mibps(5)})
    refute NodeState.fits?(state, spec(%{net_bw: Bandwidth.mibps(6)}))
  end
end
