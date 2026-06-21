defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  @typedoc """
  A cold-boot source: explicit, already-jail-visible artifact paths. `boot_args`
  defaults to a standard serial console cmdline when omitted.
  """
  @type cold_source :: %{
          required(:kernel_image_path) => Path.t(),
          required(:root_drive_path) => Path.t(),
          optional(:boot_args) => String.t(),
          optional(:read_only) => boolean()
        }

  @type vm_source ::
          {:cold, cold_source()}
          | {:snapshot, Path.t()}
          | {:vm, Hyper.Vm.t()}

  @typedoc """
  The specification for creating a new VM.
  """
  @type vm_spec :: %{
          required(:source) => vm_source()
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

  Placement: a `{:vm, _}` source is co-located on the same `Hyper.Node` as the
  parent VM for the fastest boot; if that node is overloaded the VM is snapshotted
  and placed on the most available node. A `{:snapshot, _}` source is placed on the
  most available node.
  """
  @spec create_vm(vm_spec()) :: {:ok, Hyper.Vm.t()} | {:error, term()}
  def create_vm(%{source: _source}), do: raise("not implemented")

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.t()) :: node() | nil
  def whereis(vm_id), do: Hyper.Cluster.Routing.whereis(vm_id)
end
