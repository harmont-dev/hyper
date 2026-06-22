defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  @typedoc """
  The specification for creating a new VM.
  """
  @type vm_spec :: %{
          required(:source) => Hyper.Vm.source()
        }

  defmodule Layer do
    @moduledoc "A content-addressed image layer."
    @type id :: String.t()
  end

  defmodule Img do
    @moduledoc "A content-addressed image: an ordered stack of layers."
    @type id :: String.t()
  end

  @doc """
  Create a new virtual machine from the given source.

  Placement: scheduled onto the most available node, preferring nodes that
  already have the VM's image layers resident (colocation).
  """
  # Aspirational @spec for an as-yet unimplemented stub: it raises today, so its
  # success typing is none(). Suppress the contract mismatch until it is built.
  # TODO: implement create_vm/1 and drop this @dialyzer suppression.
  @dialyzer {:nowarn_function, create_vm: 1}
  @spec create_vm(vm_spec()) :: {:ok, Hyper.Vm.t()} | {:error, term()}
  def create_vm(%{source: _source}), do: raise("not implemented")

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.id()) :: node() | nil
  def whereis(vm_id), do: Hyper.Cluster.Routing.whereis(vm_id)
end
