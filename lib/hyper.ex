defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  defmodule Layer do
    @moduledoc "A content-addressed image layer."
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
      vm_id = Hyper.Vm.Id.generate()
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

  @spec resolve_arch(Hyper.Vm.Instance.arch() | nil) ::
          {:ok, Hyper.Vm.Instance.arch()} | {:error, term()}
  defp resolve_arch(nil), do: Sys.Arch.current()
  defp resolve_arch(arch), do: {:ok, arch}

  @doc """
  Run `argv` inside the guest VM `vm` and return its captured output.

  Returns `{:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}`, or
  `{:error, reason}` — e.g. `:agent_unavailable` if the guest agent is not yet
  listening, `:not_found` if the VM id cannot be resolved. `opts`: `:env`
  (map), `:cwd` (string), `:timeout` (ms).
  """
  @spec exec(Hyper.Vm.t(), [String.t()], keyword()) ::
          {:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}
          | {:error, term()}
  def exec(vm, argv, opts \\ []) when is_pid(vm) and is_list(argv) do
    # v1: assumes the VM is placed on the local node; remote routing is not yet built.
    case id(vm) do
      nil ->
        {:error, :not_found}

      vm_id ->
        Hyper.Node.FireVMM.Exec.run(Hyper.Node.FireVMM.Jailer.host_vsock(vm_id), argv, opts)
    end
  end

  @doc "Cluster-wide: which node currently runs `vm_id`? `nil` if unknown."
  @spec whereis(Hyper.Vm.Id.t()) :: node() | nil
  def whereis(vm_id), do: Hyper.Cluster.Routing.whereis(vm_id)

  @doc """
  The vm id for a VM handle -- the pid returned by `create_vm/1`. Resolves on the
  pid's owning node, so a VM just placed on a remote node is found immediately
  rather than waiting for the routing CRDT to propagate. `nil` if unknown.

  Returns `nil` (rather than crashing the caller) if the owning node is
  unreachable -- e.g. it died with a VM just placed on it. In that case the VM
  died with its host, so "unknown" is the truthful answer. Only `:erpc`'s own
  transport failures are swallowed; a genuine fault in the lookup still raises.
  """
  @spec id(Hyper.Vm.t()) :: Hyper.Vm.Id.t() | nil
  def id(pid) when is_pid(pid) do
    :erpc.call(node(pid), Hyper.Cluster.Routing, :id_for, [pid])
  catch
    :error, {:erpc, _} -> nil
  end
end
