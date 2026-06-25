defmodule Hyper.Cluster.Scheduler do
  @moduledoc """
  Picks the node to run a VM on. The first pass reads the gossip-replicated
  `Hyper.Node.Budget.NodeState`s (`Hyper.Cluster.Budget.all_states/0`), drops
  nodes that cannot fit the spec, and ranks survivors by how many bytes of the
  VM's image layers they already have mounted (`colo(N, VM) = sum of |L|` over
  shared mounted layers). The result is an ordered candidate list; the chosen
  node confirms authoritatively via `Hyper.Node.Budget.admit/2` (see `place/3`).

  All filtering is best-effort on a possibly-stale snapshot: a node that no
  longer fits simply refuses at confirmation time.
  """

  alias Hyper.Cluster.Budget
  alias Hyper.Node.Budget.NodeState
  alias Hyper.Vm.Instance.Spec
  alias Unit.Information

  use OpenTelemetryDecorator

  @type layer_sizes :: [{Hyper.Layer.id(), Unit.Information.t()}]

  @doc "Fitting nodes for `spec`, most colocated bytes first."
  @spec candidates(Spec.t(), layer_sizes()) :: [node()]
  @decorate with_span("Hyper.Cluster.Scheduler.candidates", include: [:spec])
  def candidates(spec, layers \\ []) do
    Budget.all_states()
    |> Enum.filter(&NodeState.fits?(&1, spec))
    |> Enum.sort_by(&colocation_score(&1, layers), :desc)
    |> Enum.map(& &1.node)
  end

  @doc """
  Place `spec` on the best confirming node.

  Walks `candidates/2` in rank order, calling `attempt` on each until one returns
  `{:ok, result}` (the authoritative confirmation, typically a node running
  `Hyper.Node.try_run/3` over `:erpc`). `{:error, :no_capacity}` if all refuse.
  """
  @spec place(Spec.t(), layer_sizes(), (node() -> {:ok, term()} | {:error, term()})) ::
          {:ok, {node(), term()}} | {:error, :no_capacity}
  @decorate with_span("Hyper.Cluster.Scheduler.place", include: [:spec])
  def place(spec, layers, attempt) do
    spec
    |> candidates(layers)
    |> Enum.reduce_while({:error, :no_capacity}, fn node, acc ->
      case attempt.(node) do
        {:ok, result} -> {:halt, {:ok, {node, result}}}
        {:error, _reason} -> {:cont, acc}
      end
    end)
  end

  @doc """
  Place and boot `spec` somewhere in the cluster.

  Confirms each candidate by RPC-ing `Hyper.Node.try_run/3` on it; the first node
  to boot the VM and reserve its budget wins. `start_fun`/`stop_fun` describe how
  to boot/tear down the VM on the target node.
  """
  @spec run(
          Spec.t(),
          layer_sizes(),
          (-> {:ok, pid()} | {:error, term()}),
          (pid() -> :ok)
        ) :: {:ok, {node(), pid()}} | {:error, :no_capacity}
  @decorate with_span("Hyper.Cluster.Scheduler.run", include: [:spec])
  def run(spec, layers, start_fun, stop_fun) do
    attempt = fn target ->
      :erpc.call(target, Hyper.Node, :try_run, [spec, start_fun, stop_fun])
    end

    place(spec, layers, attempt)
  end

  @doc "Bytes of `layers` already mounted on `state`'s node."
  @spec colocation_score(NodeState.t(), layer_sizes()) :: non_neg_integer()
  def colocation_score(state, layers) do
    mounted = MapSet.new(state.layers)

    Enum.reduce(layers, 0, fn {id, size}, acc ->
      if MapSet.member?(mounted, id), do: acc + Information.as_bytes(size), else: acc
    end)
  end
end
