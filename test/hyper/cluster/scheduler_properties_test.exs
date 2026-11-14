defmodule Hyper.Cluster.SchedulerPropertiesTest do
  @moduledoc """
  Laws for placement (`Hyper.Cluster.Scheduler`).

    * `colocation_score/2` equals an independent oracle — the bytes of the
      VM's layers that are mounted on the node — is invariant under
      reordering the layers, and is unchanged by adding a layer the node does
      not hold;
    * `candidates/2` lists every fitting node exactly once, most colocated
      bytes first;
    * `place/3` walks candidates in rank order, confirming each at most once:
      it stops at the first confirmation (never confirming a second node, so a
      VM is never duplicated), stops at the first node lost mid-call (which
      may have booted the VM) with `:node_unreachable`, skips refusals, and
      answers `:no_capacity` only when every candidate refused.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Scheduler
  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance.Spec
  alias Unit.{Bandwidth, Information}

  @moduletag :capture_log

  setup do
    if Process.whereis(Budget.name()) do
      :ok
    else
      _ = Application.ensure_all_started(:horde)
      start_supervised!(Budget)
      :ok
    end
  end

  defp layer_ids, do: list_of(string(:alphanumeric, min_length: 1, max_length: 6), max_length: 8)

  defp sized_layers do
    gen all(
          ids <- uniq_list_of(string(:alphanumeric, min_length: 1, max_length: 6), max_length: 8),
          sizes <- list_of(integer(0..1_000_000), length: length(ids))
        ) do
      Enum.zip(ids, Enum.map(sizes, &Information.bytes/1))
    end
  end

  property "colocation score is the byte sum of the VM's layers the node has mounted" do
    check all(layers <- sized_layers(), mounted <- layer_ids()) do
      state = node_state(:oracle@nowhere, mounted)
      mounted_set = MapSet.new(mounted)

      oracle =
        for {id, size} <- layers, MapSet.member?(mounted_set, id), reduce: 0 do
          acc -> acc + Information.as_bytes(size)
        end

      assert Scheduler.colocation_score(state, layers) == oracle
      assert Scheduler.colocation_score(state, Enum.reverse(layers)) == oracle
    end
  end

  property "a layer the node does not hold never changes its score" do
    check all(layers <- sized_layers(), mounted <- layer_ids(), size <- integer(1..1_000_000)) do
      state = node_state(:oracle@nowhere, mounted)
      foreign = {"not-mounted-" <> Enum.join(mounted, "-"), Information.bytes(size)}

      assert Scheduler.colocation_score(state, [foreign | layers]) ==
               Scheduler.colocation_score(state, layers)
    end
  end

  property "candidates are every fitting node once, most colocated bytes first" do
    check all(count <- integer(1..5), bytes <- uniq_list_of(integer(1..1_000), length: count)) do
      nodes = Enum.map(1..count, &:"cand_#{&1}@nowhere")
      states = Enum.zip(nodes, bytes)
      layers = Enum.map(states, fn {node, b} -> {layer_for(node), Information.mib(b)} end)

      ranked = with_advertised(nodes, fn -> Scheduler.candidates(spec(), layers) end)

      expected = states |> Enum.sort_by(&elem(&1, 1), :desc) |> Enum.map(&elem(&1, 0))
      assert ranked == expected
    end
  end

  property "place confirms at most one node, in rank order, stopping at the first ok or loss" do
    check all(outcomes <- list_of(member_of([:ok, :refuse, :lost]), min_length: 1, max_length: 5)) do
      nodes = Enum.map(1..length(outcomes), &:"walk_#{&1}@nowhere")
      plan = Map.new(Enum.zip(nodes, outcomes))
      layers = nodes |> Enum.with_index() |> Enum.map(&rank_layer/1)
      test = self()

      attempt = fn node ->
        send(test, {:attempt, node})

        case Map.fetch!(plan, node) do
          :ok -> {:ok, {:booted_on, node}}
          :refuse -> {:error, :mem_exhausted}
          :lost -> {:error, {:lost_mid_call, :noconnection}}
        end
      end

      result = with_advertised(nodes, fn -> Scheduler.place(spec(), layers, attempt) end)
      attempted = drain_attempts()

      {walked, rest} = Enum.split_while(Enum.zip(nodes, outcomes), &(elem(&1, 1) == :refuse))

      {expected_attempts, expected_result} =
        case rest do
          [{node, :ok} | _] ->
            {Enum.map(walked, &elem(&1, 0)) ++ [node], {:ok, {node, {:booted_on, node}}}}

          [{node, :lost} | _] ->
            {Enum.map(walked, &elem(&1, 0)) ++ [node], {:error, :node_unreachable}}

          [] ->
            {nodes, {:error, :no_capacity}}
        end

      assert attempted == expected_attempts
      assert result == expected_result
    end
  end

  defp drain_attempts(acc \\ []) do
    receive do
      {:attempt, node} -> drain_attempts([node | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp rank_layer({node, i}), do: {layer_for(node), Information.mib(1_000 - i)}

  defp layer_for(node), do: "layer-" <> Atom.to_string(node)

  defp with_advertised(nodes, fun) do
    keys =
      Enum.map(nodes, fn node ->
        key = {:node, {__MODULE__, node}}

        {:ok, _} =
          Horde.Registry.register(Budget.name(), key, node_state(node, [layer_for(node)]))

        key
      end)

    await_fitting(length(nodes))

    try do
      fun.()
    after
      Enum.each(keys, &Horde.Registry.unregister(Budget.name(), &1))
      await_fitting(0)
    end
  end

  defp await_fitting(n, tries \\ 500) do
    fitting = Enum.count(Budget.all_states(), &NodeState.fits?(&1, spec()))

    cond do
      fitting == n -> :ok
      tries == 0 -> flunk("budget registry never settled at #{n} fitting nodes (saw #{fitting})")
      true -> await_fitting(n, tries - 1)
    end
  end

  # 64 TiB of memory: no real node's own advertisement fits, so only the
  # states this suite registers are candidates.
  defp spec do
    %Spec{
      vcpus: 1,
      mem: Information.tib(64),
      disk: Information.gib(1),
      disk_bw: Bandwidth.mibps(1),
      net_bw: Bandwidth.mibps(1)
    }
  end

  defp node_state(node, layers) do
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
      layers: layers
    }
  end
end
