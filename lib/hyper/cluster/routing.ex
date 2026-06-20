defmodule Hyper.Cluster.Routing do
  @moduledoc """
  Cluster-wide VM routing registry: maps `{vm_id, component} -> pid` so any node
  can name a VM's processes (`via/1`) and find which machine runs a VM
  (`whereis/1`). A `Horde.Registry` (DeltaCRDT) with `members: :auto`, so it
  forms over the BEAM cluster libcluster builds.

  Kept as its own CRDT, separate from `Hyper.Cluster.Budget`, so high-frequency
  budget telemetry never shares this routing table's delta stream or failure
  domain.
  """

  @name __MODULE__

  @doc "The registry name."
  @spec name() :: atom()
  def name, do: @name

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    Horde.Registry.child_spec(name: @name, keys: :unique, members: :auto)
  end

  @doc "A `:via` tuple for registering/naming a process under `key`."
  @spec via(term()) :: {:via, module(), {atom(), term()}}
  def via(key), do: {:via, Horde.Registry, {@name, key}}

  @doc "Which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.id()) :: node() | nil
  def whereis(vm_id) do
    case Horde.Registry.lookup(@name, {vm_id, :supervisor}) do
      [{pid, _}] -> node(pid)
      [] -> nil
    end
  end
end
