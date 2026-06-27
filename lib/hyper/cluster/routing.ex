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

  use OpenTelemetryDecorator

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
  @spec whereis(Hyper.Vm.Id.t()) :: node() | nil
  @decorate with_span("Hyper.Cluster.Routing.whereis", include: [:vm_id])
  def whereis(vm_id) do
    case Horde.Registry.lookup(@name, {vm_id, :supervisor}) do
      [{pid, _}] -> node(pid)
      [] -> nil
    end
  end

  @doc """
  The vm_id whose `:supervisor` process is `pid`, or `nil`. Consults the local
  replica via a registry match spec; intended to be called on the node that owns
  `pid` (see `Hyper.id/1`).
  """
  @spec id_for(pid()) :: Hyper.Vm.Id.t() | nil
  @decorate with_span("Hyper.Cluster.Routing.id_for")
  def id_for(pid) when is_pid(pid) do
    case Horde.Registry.select(@name, [
           {{{:"$1", :supervisor}, :"$2", :_}, [{:==, :"$2", pid}], [:"$1"]}
         ]) do
      [vm_id | _] -> vm_id
      [] -> nil
    end
  end

  @doc "Every VM the cluster currently knows about, paired with the node it runs on."
  @spec all() :: [{Hyper.Vm.Id.t(), node()}]
  @decorate with_span("Hyper.Cluster.Routing.all")
  def all do
    @name
    |> Horde.Registry.select([
      {{{:"$1", :supervisor}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}
    ])
    |> Enum.map(fn {vm_id, pid} -> {vm_id, node(pid)} end)
  end
end
