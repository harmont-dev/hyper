defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  @typedoc """
  What a VM boots from: explicit, already-jail-visible artifact paths for a cold
  boot (kernel + root drive). `boot_args` defaults to a standard serial-console
  cmdline when omitted.

  VMs cold-boot from a disk image; there is no snapshot/restore path. (Firecracker
  snapshots capture guest RAM + CPU state, not disk, and would be a separate axis
  layered on top of this if reintroduced.)
  """
  @type vm_source :: %{
          required(:kernel_image_path) => Path.t(),
          required(:root_drive_path) => Path.t(),
          optional(:boot_args) => String.t(),
          optional(:read_only) => boolean()
        }

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

  Placement: scheduled onto the most available node, preferring nodes that
  already have the VM's image layers resident (colocation).
  """
  @spec create_vm(vm_spec()) :: {:ok, Hyper.Vm.t()} | {:error, term()}
  def create_vm(%{source: _source}), do: raise("not implemented")

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.t()) :: node() | nil
  def whereis(vm_id), do: Hyper.Cluster.Routing.whereis(vm_id)
end
