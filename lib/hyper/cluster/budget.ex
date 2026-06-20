defmodule Hyper.Cluster.Budget do
  @moduledoc """
  Cluster-wide budget telemetry: one `Hyper.Node.Budget.NodeState` per node,
  keyed `{:node, node()}`. A `Horde.Registry` (DeltaCRDT) with `members: :auto`.

  Each node's `Hyper.Node.Budget.Advertiser` owns its entry (the registration is
  tied to that pid, so a dead node's entry disappears cluster-wide). Schedulers
  read the local replica via `all_states/0` — eventually consistent and
  partition-tolerant.
  """

  @name __MODULE__

  @doc "The registry name."
  @spec name() :: atom()
  def name, do: @name

  @doc "This node's registration key."
  @spec key() :: {:node, node()}
  def key, do: {:node, node()}

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    Horde.Registry.child_spec(name: @name, keys: :unique, members: :auto)
  end

  @doc "Every node's published `NodeState` from this node's local replica."
  @spec all_states() :: [Hyper.Node.Budget.NodeState.t()]
  def all_states do
    # Entries are {key, pid, value}; match only {:node, _} keys and take the value.
    Horde.Registry.select(@name, [{{{:node, :"$1"}, :_, :"$2"}, [], [:"$2"]}])
  end
end
