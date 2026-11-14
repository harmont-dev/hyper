defmodule Hyper.Cluster.SchedulerTest do
  use ExUnit.Case, async: false

  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Scheduler
  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  @unconnected :scheduler_test@nowhere

  setup do
    if Process.whereis(Budget.name()) do
      :ok
    else
      _ = Application.ensure_all_started(:horde)
      start_supervised!(Budget)
      :ok
    end
  end

  test "placement skips nodes it is not connected to, and stops at one lost mid-call" do
    rows = [
      {[@unconnected, node()], fn -> {:error, :refused} end, {:error, :no_capacity}},
      {[node(), @unconnected], fn -> raise "booted, then crashed" end,
       {:error, :node_unreachable}}
    ]

    for {ranked, start, expected} <- rows do
      test = self()

      start_fun = fn ->
        send(test, :started)
        start.()
      end

      result =
        with_advertised(ranked, fn layers ->
          Scheduler.run(spec(), layers, start_fun, fn _pid -> :ok end)
        end)

      assert result == expected, inspect(ranked)
      assert_received :started
      refute_received :started
    end
  end

  defp with_advertised(ranked, fun) do
    layers =
      ranked |> Enum.with_index() |> Enum.map(fn {_, i} -> {"layer-#{i}", rank_bytes(i)} end)

    keys = ranked |> Enum.with_index() |> Enum.map(fn {node, i} -> advertise(node, i) end)
    await_states(&(length(&1) == length(ranked)))

    try do
      fun.(layers)
    after
      Enum.each(keys, &Horde.Registry.unregister(Budget.name(), &1))
      await_states(&(&1 == []))
    end
  end

  defp rank_bytes(i), do: Information.mib(1_000 - i)

  defp advertise(node, i) do
    key = {:node, {__MODULE__, i}}
    {:ok, _} = Horde.Registry.register(Budget.name(), key, node_state(node, "layer-#{i}"))
    key
  end

  defp await_states(done?, tries \\ 200) do
    states = Enum.filter(Budget.all_states(), &NodeState.fits?(&1, spec()))

    cond do
      done?.(states) -> :ok
      tries == 0 -> flunk("budget registry never settled: #{inspect(states)}")
      true -> await_states(done?, tries - 1)
    end
  end

  defp spec do
    %Spec{
      vcpus: 1,
      mem: Information.tib(64),
      disk: Information.gib(1),
      disk_bw: Bandwidth.mibps(1),
      net_bw: Bandwidth.mibps(1)
    }
  end

  defp node_state(node, layer) do
    %NodeState{
      node: node,
      mem_free: Information.tib(128),
      disk_free: Information.gib(100),
      cpu_load: 0.0,
      cpu_capacity: 8,
      cpu_max_load: 1.0,
      disk_bw_load: Bandwidth.zero(),
      disk_bw_ceiling: Bandwidth.gibps(1),
      net_bw_load: Bandwidth.zero(),
      net_bw_ceiling: Bandwidth.gibps(1),
      layers: [layer]
    }
  end
end
