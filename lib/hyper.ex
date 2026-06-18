defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  @type vm_source ::
    {:snapshot, Path.t()}
    | {:vm, Hyper.Vm.t()}

  @typedoc """
  The specification for creating a new VM.
  """
  @type vm_spec :: %{
    required(:source) => vm_source(),
  }

  @doc """
  Create a new virtual machine from the given source.

  Placement: a `{:vm, _}` source is co-located on the same `Hyper.Node` as the
  parent VM for the fastest boot; if that node is overloaded the VM is snapshotted
  and placed on the most available node. A `{:snapshot, _}` source is placed on the
  most available node.
  """
  @spec create_vm(vm_spec()) :: {:ok, Hyper.Vm.t()} | {:error, term()}
  def create_vm(%{source: _source}), do: raise("not implemented")

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.t()) :: node() | nil
  def whereis(vm_id) do
    case Horde.Registry.lookup(Hyper.Vm.Registry, {vm_id, :supervisor}) do
      [{pid, _}] -> node(pid)
      [] -> nil
    end
  end
end
