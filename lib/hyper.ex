defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  @typedoc """
  The specification for creating a new VM.
  """
  @type vm_spec :: %{
          required(:img_id) => Hyper.Img.id(),
          optional(:type) => Hyper.Vm.Instance.t(),
          optional(:arch) => Hyper.Vm.Instance.arch(),
          optional(:boot_args) => String.t()
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
  Create a new virtual machine from an image.

  Placement: scheduled onto the most available node (`Hyper.Cluster.Scheduler`),
  preferring nodes that already have the image's layers resident. On the chosen
  node a per-VM writable rootfs is built over the image and the guest is booted.
  """
  @spec create_vm(vm_spec()) :: {:ok, Hyper.Vm.t()} | {:error, term()}
  def create_vm(%{img_id: img_id} = vm_spec) do
    type = Map.get(vm_spec, :type, :base)
    boot_args = Map.get(vm_spec, :boot_args)

    with {:ok, arch} <- resolve_arch(vm_spec) do
      vm_id = gen_vm_id()
      spec = Hyper.Vm.Instance.spec(type)
      params = %{vm_id: vm_id, img_id: img_id, type: type, arch: arch, boot_args: boot_args}

      start_fun = fn -> Hyper.Node.start_image_vm(params) end
      stop_fun = fn pid -> Hyper.Node.stop_image_vm(pid) end

      # Colocation hints are a best-effort optimisation; an empty list just means
      # "rank by free capacity only".
      case Hyper.Cluster.Scheduler.run(spec, [], start_fun, stop_fun) do
        {:ok, {_node, pid}} -> {:ok, pid}
        {:error, _} = err -> err
      end
    end
  end

  @doc "Generate a fresh VM id (url-safe base64, dm-name compatible)."
  @spec gen_vm_id() :: Hyper.Vm.id()
  def gen_vm_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  defp resolve_arch(%{arch: arch}), do: {:ok, arch}
  defp resolve_arch(_), do: Sys.Arch.current()

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.t()) :: node() | nil
  def whereis(vm_id), do: Hyper.Cluster.Routing.whereis(vm_id)
end
