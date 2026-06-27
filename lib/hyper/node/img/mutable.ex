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

  use GenServer

  alias Hyper.Node.Img
  alias Hyper.Node.Img.{Server, ThinPool}
  alias Hyper.SuidHelper

  use OpenTelemetryDecorator

  defmodule Opts do
    @moduledoc false
    @enforce_keys [:img_id, :vm_id]
    defstruct [:img_id, :vm_id]

    @type t :: %__MODULE__{img_id: Hyper.Img.id(), vm_id: Hyper.Vm.id()}
  end

  defmodule State do
    @moduledoc false
    defstruct [:img_server, :thin_name, :thin_id, :blk_path, holders: %{}, idle_ref: nil]

    @type t :: %__MODULE__{
            img_server: GenServer.server(),
            thin_name: String.t(),
            thin_id: non_neg_integer(),
            blk_path: Path.t(),
            holders: %{pid() => reference()},
            idle_ref: reference() | nil
          }
  end

  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts), do: GenServer.start_link(__MODULE__, opts)

  @spec blk_path(GenServer.server()) :: Path.t()
  def blk_path(server), do: GenServer.call(server, :blk_path)

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
  def init(%Opts{img_id: img_id, vm_id: vm_id}) do
    Process.flag(:trap_exit, true)
    name = dm_name(vm_id)

    with {:ok, img_server} <- Img.activate(img_id),
         :ok <- Server.acquire(img_server),
         ro_dev = Server.blk_path(img_server),
         {:ok, sectors} <- SuidHelper.Blockdev.device_sectors(ro_dev),
         {:ok, %{dev: dev, id: id}} <- ThinPool.create_external(name, ro_dev, sectors) do
      state = %State{
        img_server: img_server,
        thin_name: name,
        thin_id: id,
        blk_path: dev
      }

      {:ok, arm_idle(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:blk_path, _from, state), do: {:reply, state.blk_path, state}

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
  # here afterwards -- stale by construction, whatever its reason -- so ignore any
  # port exit. (A linked *process* exiting is a different event and still raises.)
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Destroy the thin volume, then release the image (its monitor on us also
    # fires, but releasing explicitly keeps teardown deterministic).
    if state.thin_name && state.thin_id, do: ThinPool.destroy(state.thin_name, state.thin_id)
    if state.img_server, do: Server.release(state.img_server)
    :ok
  end

  @doc false
  @spec dm_name(Hyper.Vm.id()) :: String.t()
  def dm_name(vm_id), do: "hyper-rw-#{sanitize(vm_id)}"

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
