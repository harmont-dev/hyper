defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

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
  @spec create_vm(Hyper.Vm.Spec.t()) :: {:ok, Hyper.Vm.t()} | {:error, term()}
  def create_vm(%Hyper.Vm.Spec{} = spec) do
    with {:ok, arch} <- resolve_arch(spec.arch) do
      vm_id = gen_vm_id()
      spec = %{spec | arch: arch}
      instance_spec = Hyper.Vm.Instance.spec(spec.type)

      start_fun = fn -> Hyper.Node.start_image_vm(vm_id, spec) end
      stop_fun = fn pid -> Hyper.Node.stop_image_vm(pid) end

      # Colocation hints are a best-effort optimisation; an empty list just means
      # "rank by free capacity only".
      case Hyper.Cluster.Scheduler.run(instance_spec, [], start_fun, stop_fun) do
        {:ok, {_node, pid}} -> {:ok, pid}
        {:error, _} = err -> err
      end
    end
  end

  @doc "Generate a fresh VM id (url-safe base64, dm-name compatible)."
  @spec gen_vm_id() :: Hyper.Vm.id()
  def gen_vm_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

  @spec resolve_arch(Hyper.Vm.Instance.arch() | nil) ::
          {:ok, Hyper.Vm.Instance.arch()} | {:error, term()}
  defp resolve_arch(nil), do: Sys.Arch.current()
  defp resolve_arch(arch), do: {:ok, arch}

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.id()) :: node() | nil
  def whereis(vm_id), do: Hyper.Cluster.Routing.whereis(vm_id)
end
