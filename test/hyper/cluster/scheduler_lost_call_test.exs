defmodule Hyper.Cluster.SchedulerLostCallTest do
  @moduledoc """
  The no-duplicate contract of `Hyper.Cluster.Scheduler.run/4` (#134): once a
  confirming call to a reachable candidate fails in a way that leaves it unknown
  whether the VM booted there, placement stops with `{:error,
  :node_unreachable}` instead of booting the same VM on the next node — and it
  never lets that failure escape as an exception, which the gRPC boundary would
  turn into UNKNOWN instead of UNAVAILABLE. This must hold for every way
  `:erpc.call/4` reports a failed remote apply: raise, exit, and throw.
  """
  use ExUnit.Case, async: false

  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Scheduler
  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  @moduletag :capture_log
  @behind :lost_call_test_behind@nowhere

  setup do
    if Process.whereis(Budget.name()) do
      :ok
    else
      _ = Application.ensure_all_started(:horde)
      start_supervised!(Budget)
      :ok
    end
  end

  for kind <- [:raise, :exit, :exit_normal, :throw] do
    test "a confirming call that fails by #{kind} stops placement as :node_unreachable" do
      test = self()

      start_fun = fn ->
        send(test, :started)
        fail(unquote(kind))
      end

      result =
        with_advertised([node(), @behind], fn layers ->
          try do
            Scheduler.run(spec(), layers, start_fun, fn _pid -> :ok end)
          catch
            kind, reason -> {:escaped, kind, reason}
          end
        end)

      assert result == {:error, :node_unreachable}
      assert_received :started
      refute_received :started
    end
  end

  defp fail(:raise), do: raise("booted, then crashed")
  defp fail(:exit), do: exit(:boot_wedged)
  defp fail(:exit_normal), do: exit(:normal)
  defp fail(:throw), do: throw(:boot_aborted)

  defp with_advertised(ranked, fun) do
    layers =
      ranked
      |> Enum.with_index()
      |> Enum.map(fn {_, i} -> {"lost-#{i}", Information.mib(900 - i)} end)

    keys =
      ranked
      |> Enum.with_index()
      |> Enum.map(fn {node, i} ->
        key = {:node, {__MODULE__, i}}
        {:ok, _} = Horde.Registry.register(Budget.name(), key, node_state(node, "lost-#{i}"))
        key
      end)

    await_fitting(length(ranked))

    try do
      fun.(layers)
    after
      Enum.each(keys, &Horde.Registry.unregister(Budget.name(), &1))
      await_fitting(0)
    end
  end

  defp await_fitting(n, tries \\ 500) do
    fitting = Enum.count(Budget.all_states(), &NodeState.fits?(&1, spec()))

    cond do
      fitting == n -> :ok
      tries == 0 -> flunk("budget registry never settled at #{n} fitting nodes")
      true -> await_fitting(n, tries - 1)
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
