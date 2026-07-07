defmodule Hyper.Node.Img.Mutable do
  @moduledoc """
  The per-VM mutable rootfs. On start it activates (or reuses) the image's
  read-only `Img.Server`, takes a reference on it, reads the composed device's
  size, and asks the node `ThinPool` for a thin volume with that device as a
  read-only external origin. `blk_path/1` is the mutable host device the VM
  boots from (staged into the jail by `mknod` from this path).

  Mutable layers live in their own `DynamicSupervisor`, separate from the shared
  read-only `Img.Server`s; the firecracker VM is handed this layer directly and
  cannot be booted from a bare `Hyper.Img`.

  Monitor-refcounted like `Img.Server`/`Layer.Server`: the VM supervisor holds
  it; when the last holder dies it idle-reaps, destroying its thin volume in
  `terminate/2` and releasing the image (which, if it was the last holder, tears
  down the RO chain in turn).
  """

  # `:temporary` is load-bearing: on idle this server destroys its per-VM thin
  # volume in `terminate/2`, so a `:permanent` restart would resurrect the dm
  # device it just tore down. See the reconciliation TODO in `Hyper.Node.Reaper`
  # for why coupling resource lifetime to process lifetime is a smell.
  use GenServer, restart: :temporary

  alias Hyper.Node.Img
  alias Hyper.Node.Img.{Server, ThinPool}
  alias Hyper.SuidHelper

  use OpenTelemetryDecorator

  defmodule Opts do
    @moduledoc false
    @enforce_keys [:img_id, :vm_id]
    defstruct [:img_id, :vm_id, fork_of: nil]

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id(),
            vm_id: Hyper.Vm.Id.t(),
            fork_of: Hyper.Vm.Id.t() | nil
          }
  end

  defmodule State do
    @moduledoc false
    defstruct [
      :img_id,
      :img_server,
      :origin_dev,
      :thin_name,
      :thin_id,
      :blk_path,
      holders: %{},
      idle_ref: nil
    ]

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id(),
            img_server: GenServer.server(),
            origin_dev: Path.t(),
            thin_name: String.t(),
            thin_id: non_neg_integer(),
            blk_path: Path.t(),
            holders: %{pid() => reference()},
            idle_ref: reference() | nil
          }
  end

  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{vm_id: vm_id} = opts),
    do: GenServer.start_link(__MODULE__, opts, name: via(vm_id))

  @spec blk_path(GenServer.server()) :: Path.t()
  def blk_path(server), do: GenServer.call(server, :blk_path)

  @doc """
  The volume's identity for forking: which image it serves, its thin name/id in
  the node pool, its device path, and the composed RO origin it reads through.
  """
  @spec describe(GenServer.server()) :: %{
          img_id: Hyper.Img.id(),
          thin_name: String.t(),
          thin_id: non_neg_integer(),
          blk_path: Path.t(),
          origin_dev: Path.t()
        }
  def describe(server), do: GenServer.call(server, :describe)

  @spec acquire(GenServer.server()) :: :ok
  def acquire(server), do: acquire(server, self())

  @spec acquire(GenServer.server(), pid()) :: :ok
  def acquire(server, holder), do: GenServer.call(server, {:acquire, holder})

  @doc """
  Release the calling process's hold on the writable volume.

  The VM-supervisor holder is released via its monitor :DOWN, not this function.
  """
  @spec release(GenServer.server()) :: :ok
  def release(server), do: GenServer.call(server, {:release, self()})

  @impl true
  @decorate with_span("Hyper.Node.Img.Mutable.init", include: [:img_id, :vm_id])
  def init(%Opts{img_id: img_id, vm_id: vm_id, fork_of: nil}) do
    Process.flag(:trap_exit, true)
    name = dm_name(vm_id)

    with {:ok, img_server} <- Img.activate(img_id),
         :ok <- Server.acquire(img_server),
         ro_dev = Server.blk_path(img_server),
         {:ok, sectors} <- SuidHelper.Blockdev.device_sectors(ro_dev),
         {:ok, %{dev: dev, id: id}} <- ThinPool.create_external(name, ro_dev, sectors) do
      state = %State{
        img_id: img_id,
        img_server: img_server,
        origin_dev: ro_dev,
        thin_name: name,
        thin_id: id,
        blk_path: dev
      }

      {:ok, arm_idle(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @decorate with_span("Hyper.Node.Img.Mutable.init_fork",
              include: [:img_id, :vm_id, :parent_vm_id]
            )
  def init(%Opts{img_id: img_id, vm_id: vm_id, fork_of: parent_vm_id}) do
    Process.flag(:trap_exit, true)
    name = dm_name(vm_id)

    with {:ok, parent} <- lookup(parent_vm_id),
         # Hold the parent so it cannot idle-reap (freeing its thin id) between
         # describe and create_snap; released once the snapshot is independent.
         :ok <- acquire(parent, self()),
         %{thin_name: origin_name, thin_id: origin_id} = describe(parent),
         {:ok, img_server} <- Img.activate(img_id),
         :ok <- Server.acquire(img_server),
         ro_dev = Server.blk_path(img_server),
         {:ok, sectors} <- SuidHelper.Blockdev.device_sectors(ro_dev),
         {:ok, %{dev: dev, id: id}} <-
           ThinPool.snapshot(name, origin_name, origin_id, sectors, ro_dev) do
      release_parent(parent)

      state = %State{
        img_id: img_id,
        img_server: img_server,
        origin_dev: ro_dev,
        thin_name: name,
        thin_id: id,
        blk_path: dev
      }

      {:ok, arm_idle(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @spec lookup(Hyper.Vm.Id.t()) ::
          {:ok, pid()} | {:error, {:parent_mutable_not_found, Hyper.Vm.Id.t()}}
  defp lookup(vm_id) do
    case Registry.lookup(Img.mutable_registry(), vm_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, {:parent_mutable_not_found, vm_id}}
    end
  end

  # Dropping our hold on the parent after the snapshot is best-effort: a parent
  # that died in the meantime needs no release (its holder map died with it),
  # and the child's snapshot is already independent — aborting init here would
  # strand the volume we just created until the Reaper collects it.
  @spec release_parent(pid()) :: :ok
  defp release_parent(parent) do
    release(parent)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_call(:blk_path, _from, state), do: {:reply, state.blk_path, state}

  @impl true
  def handle_call(:describe, _from, state) do
    reply = %{
      img_id: state.img_id,
      thin_name: state.thin_name,
      thin_id: state.thin_id,
      blk_path: state.blk_path,
      origin_dev: state.origin_dev
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:acquire, pid}, _from, %State{holders: holders} = state) do
    state = cancel_idle(state)

    holders =
      if Map.has_key?(holders, pid),
        do: holders,
        else: Map.put(holders, pid, Process.monitor(pid))

    {:reply, :ok, %{state | holders: holders}}
  end

  @impl true
  def handle_call({:release, pid}, _from, state), do: {:reply, :ok, drop(state, pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state), do: {:noreply, drop(state, pid)}

  @impl true
  def handle_info(:idle_timeout, %State{holders: holders} = state) when map_size(holders) == 0 do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:idle_timeout, state), do: {:noreply, state}

  @impl true
  # Each privileged command runs through `System.cmd`, which links a transient
  # port to this process and returns only once that command has finished. Because
  # we trap exits (for `terminate/2` teardown), the now-defunct port's exit lands
  # here afterwards -- stale by construction, whatever its reason -- so ignore it.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  @impl true
  # No process is deliberately linked here beyond those transient command ports,
  # so a linked *process* EXIT is a genuine fault: propagate its reason (so
  # terminate/2 still runs teardown) rather than crash opaquely on an unmatched
  # message.
  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  @impl true
  def terminate(_reason, state) do
    # Destroy the thin volume, then release the image (its monitor on us also
    # fires, but releasing explicitly keeps teardown deterministic).
    if state.thin_name && state.thin_id, do: ThinPool.destroy(state.thin_name, state.thin_id)
    if state.img_server, do: Server.release(state.img_server)
    :ok
  end

  @doc false
  @spec dm_name(Hyper.Vm.Id.t()) :: String.t()
  def dm_name(vm_id), do: "hyper-rw-#{sanitize(vm_id)}"

  @doc "vm_ids of every live mutable layer on this node."
  @spec active_vm_ids() :: [Hyper.Vm.Id.t()]
  def active_vm_ids do
    Registry.select(Img.mutable_registry(), [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  defp via(vm_id), do: {:via, Registry, {Img.mutable_registry(), vm_id}}

  defp sanitize(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  @spec drop(State.t(), pid()) :: State.t()
  defp drop(%State{holders: holders} = state, pid) do
    case Map.pop(holders, pid) do
      {nil, _} ->
        state

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        state = %{state | holders: holders}
        if map_size(holders) == 0, do: arm_idle(state), else: state
    end
  end

  # How long an idle mutable layer lingers with no users before it is torn down.
  @idle_grace :timer.seconds(30)

  defp arm_idle(state) do
    state = cancel_idle(state)

    %{state | idle_ref: Process.send_after(self(), :idle_timeout, @idle_grace)}
  end

  defp cancel_idle(%State{idle_ref: nil} = state), do: state

  defp cancel_idle(%State{idle_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | idle_ref: nil}
  end
end
