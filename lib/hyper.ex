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

      # Rank candidates by how many of the image's layer bytes they already
      # have mounted; a fork's freshly published delta is resident nowhere yet,
      # so its parent's base layers dominate the score — which is the point.
      layers = Hyper.Img.Db.Image.chain_sizes(spec.img_id)

      case Hyper.Cluster.Scheduler.run(instance_spec, layers, start_fun, stop_fun) do
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
  Run `argv` inside VM `vm` — a pid (from `create_vm/1`) or a `Hyper.Vm.Id.t()`
  binary — and return its captured output.

  Cluster-routed: a pid resolves to its owning node directly (`node(pid)`); a
  vm_id resolves via the routing registry (`whereis/1`). The command runs on
  whichever node hosts the VM, via that node's `Hyper.Node.exec/3`.

  Returns `{:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}`, or
  `{:error, reason}` — `:agent_unavailable` if the relay/agent is not yet
  reachable, `:timeout` if the gRPC deadline expired, `:not_found` if the VM
  cannot be resolved (unknown vm_id, or a pid whose id/owning node is gone),
  `:node_unreachable` if the owning node cannot be reached over the cluster.
  `opts`: `:env` (map `%{String.t() => String.t()}`), `:cwd` (string), `:timeout`
  (ms, gRPC deadline forwarded to the relay; default 30 000).

  `argv` is executed directly, not through a shell. Use an **absolute** `argv`
  head (`["/bin/echo", "hi"]`): the guest runs as PID 1 with a near-empty
  environment, and a non-empty `:env` *replaces* it entirely, so a bare command
  name has no `PATH` to resolve against and returns exit code 127.
  """
  @spec exec(Hyper.Vm.t() | Hyper.Vm.Id.t(), [String.t()], keyword()) ::
          {:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}
          | {:error, term()}
  def exec(vm, argv, opts \\ [])

  def exec(vm, argv, opts) when is_pid(vm) and is_list(argv) do
    case id(vm) do
      nil -> {:error, :not_found}
      vm_id -> route(node(vm), vm_id, argv, opts)
    end
  end

  def exec(vm_id, argv, opts) when is_binary(vm_id) and is_list(argv) do
    case whereis(vm_id) do
      nil -> {:error, :not_found}
      node -> route(node, vm_id, argv, opts)
    end
  end

  # Run the node-local exec on the VM's owning node. A pid already carries its
  # node; a vm_id was resolved through the routing registry. Transport failures
  # (owning node down/partitioned) become `:node_unreachable` rather than a raise
  # in the caller — the VM is unusable from here either way.
  @spec route(node(), Hyper.Vm.Id.t(), [String.t()], keyword()) ::
          {:ok, %{stdout: binary(), stderr: binary(), exit_code: integer()}}
          | {:error, term()}
  defp route(node, vm_id, argv, opts) do
    :erpc.call(node, Hyper.Node, :exec, [vm_id, argv, opts])
  catch
    :error, {:erpc, _} -> {:error, :node_unreachable}
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
