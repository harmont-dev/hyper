defmodule Hyper.Node.Img do
  @moduledoc """
  Supervisor for this node's active images, and the entry point for image
  operations. Owns:

    * a unique `Registry` (`img_id -> Img.Server`), and
    * a `DynamicSupervisor` holding the (shared, read-only) image servers, and
    * a *separate* `DynamicSupervisor` holding the per-VM mutable layers
      (`Img.Mutable`), so the writable layers form their own process tree.
    * a `ThinPool`, per node, which manages each `dm-thin` instance on this machine.

  On top of that tree it leases an image for the lifetime of a VM
  (`with_image/3`).
  """
  use Supervisor

  alias Hyper.Img.Db
  alias Hyper.Node.Img.Mutable
  alias Hyper.Node.Img.Server
  alias Hyper.Node.Img.ThinPool

  @registry Hyper.Node.Img.Registry
  @mutable_registry Hyper.Node.Img.MutableRegistry
  @server_sup Hyper.Node.Img.Supervisor
  @mutable_sup Hyper.Node.Img.MutableSupervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {Registry, keys: :unique, name: @mutable_registry},
      ThinPool,
      {DynamicSupervisor, strategy: :one_for_one, name: @server_sup},
      {DynamicSupervisor, strategy: :one_for_one, name: @mutable_sup}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def registry, do: @registry

  @doc false
  @spec mutable_registry() :: atom()
  def mutable_registry, do: @mutable_registry

  @doc "Activate `img_id` on this node: start (or reuse) its image server."
  @spec activate(Hyper.Img.id()) :: {:ok, pid()} | {:error, term()}
  def activate(img_id) do
    case DynamicSupervisor.start_child(@server_sup, {Server, %Server.Opts{img_id: img_id}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  @doc "Create a per-VM mutable layer for `vm_id` over `img_id`."
  @spec create_mutable(Hyper.Img.id(), Hyper.Vm.Id.t()) :: {:ok, pid()} | {:error, term()}
  def create_mutable(img_id, vm_id) do
    # Unlike activate/1, we intentionally do NOT map {:already_started, pid} -> {:ok, pid}:
    # vm_ids are unique per VM, so a duplicate vm_id is a bug, not a shared-server reuse.
    # Surfacing {:error, {:already_started, pid}} enforces the one-mutable-per-vm invariant.
    case DynamicSupervisor.start_child(
           @mutable_sup,
           {Mutable, %Mutable.Opts{img_id: img_id, vm_id: vm_id}}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  @doc "Every image id currently active on this node."
  @spec active() :: [Hyper.Img.id()]
  def active do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc """
  Serve `img` to `vm_id` for the duration of `callable`, holding a DB lease on the
  image (and transitively its whole blob chain) the whole time.
  """
  @spec with_image(Hyper.Img.id(), Hyper.Vm.Id.t(), (-> result)) :: result | {:error, term()}
        when result: var
  def with_image(img, vm_id, callable) do
    with_image_lease(img, vm_id, callable)
  end

  # Take a lease on `img` for this node/`vm_id`, run `callable`, then release it -
  # even if `callable` raises. A background task re-bumps the lease for the whole
  # run, so a long-lived VM never lets its claim lapse. If the lease cannot be
  # taken, returns the error and never runs `callable`.
  @spec with_image_lease(Hyper.Img.id(), Hyper.Vm.Id.t(), (-> result)) ::
          result | {:error, term()}
        when result: var
  defp with_image_lease(img, vm_id, callable) do
    ttl = Db.Lease.default_ttl()

    with {:ok, _lease} <- Db.Lease.bump(img, vm_id, ttl) do
      task = Task.async(fn -> heartbeat(img, vm_id, ttl) end)

      try do
        callable.()
      after
        _ = Task.shutdown(task, :brutal_kill)
        :ok = Db.Lease.release(vm_id)
      end
    end
  end

  # Re-bump the lease forever at 1/3 of the TTL, until killed. Runs in a task for the
  # lifetime of `callable`; transient bump failures are swallowed so a DB hiccup
  # can't tear down the VM - the next tick retries.
  @spec heartbeat(Hyper.Img.id(), Hyper.Vm.Id.t(), Unit.Time.t()) :: no_return()
  defp heartbeat(img, vm_id, ttl) do
    Process.sleep(div(Unit.Time.as_ms(ttl), 3))

    _ =
      try do
        Db.Lease.bump(img, vm_id, ttl)
      rescue
        _ -> :ok
      end

    heartbeat(img, vm_id, ttl)
  end
end
