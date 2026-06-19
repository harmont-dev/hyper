defmodule Hyper.Node.Layer.Server do
  @moduledoc """
  GenServer responsible for managing a single mounted layer.

  Reference-counted via process monitors: each holder `acquire/1`s the layer and
  the server monitors it, so a holder that crashes is released automatically (no
  leaked count). When the last holder goes away the server waits a short idle
  grace period and then stops, unmounting the block device in `terminate/2`.
  """

  use GenServer
  require Logger

  alias Hyper.Node.Layer
  alias Hyper.Node.Layer.Repo
  alias Hyper.Sys.Linux.Losetup

  # Grace period after the last holder leaves before the layer is unmounted. Keeps
  # bursty acquire/release cycles from thrashing the mount.
  @idle_timeout_ms :timer.seconds(30)

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            blk_path: Path.t(),
            holders: %{pid() => reference()},
            idle_ref: reference() | nil
          }

    defstruct [:blk_path, holders: %{}, idle_ref: nil]
  end

  defmodule Opts do
    @moduledoc false

    @type t :: %__MODULE__{
            layer_id: Hyper.Layer.id()
          }

    defstruct [:layer_id]
  end

  @doc "Get the server mounting `layer_id`, starting it under the layer supervisor if needed."
  @spec for_layer(Hyper.Layer.id()) :: {:ok, pid()} | {:error, term()}
  def for_layer(layer_id) do
    case Registry.lookup(Layer.registry(), layer_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> Layer.start_server(layer_id)
    end
  end

  @doc """
  Take a reference on `server` on behalf of the calling process. The layer stays
  mounted until every holder releases (or dies). Idempotent per process.
  """
  @spec acquire(GenServer.server()) :: :ok
  def acquire(server), do: GenServer.call(server, {:acquire, self()})

  @doc "Drop the calling process's reference on `server`."
  @spec release(GenServer.server()) :: :ok
  def release(server), do: GenServer.call(server, {:release, self()})

  @doc "Get the block device path of the layer managed by `server`."
  @spec blk_path(GenServer.server()) :: Path.t()
  def blk_path(server), do: GenServer.call(server, :blk_path)

  @doc "Create a new layer, mounting it as a block device."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{layer_id: layer_id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via(layer_id))
  end

  @impl true
  def init(%Opts{layer_id: layer_id}) do
    Process.flag(:trap_exit, true)

    with {:ok, layer_path} <- Repo.find_layer(layer_id),
         {:ok, blk_path} <- Losetup.mount_ro(layer_path) do
      # Start with no holders, so a mounted-but-unused layer reaps itself.
      {:ok, arm_idle(%State{blk_path: blk_path})}
    else
      {:error, reason} -> {:stop, reason}
    end
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
  def handle_call({:release, pid}, _from, state) do
    {:reply, :ok, drop(state, pid)}
  end

  @impl true
  def handle_call(:blk_path, _from, %State{blk_path: blk_path} = state) do
    {:reply, blk_path, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    {:noreply, drop(state, pid)}
  end

  @impl true
  def handle_info(:idle_timeout, %State{holders: holders} = state) when map_size(holders) == 0 do
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    # Stale timer (a holder arrived after it was armed) — ignore.
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %State{blk_path: blk_path}) do
    case Losetup.umount(blk_path) do
      {:ok, _path} ->
        :ok

      {:error, {errc, out}} ->
        Logger.error("Failed to unmount layer block device #{blk_path} (exit #{errc}): #{out}")
        :ok
    end
  end

  # Remove `pid` from the holder set (no-op if it isn't one) and re-arm the idle
  # timer if that was the last holder.
  @spec drop(State.t(), pid()) :: State.t()
  defp drop(%State{holders: holders} = state, pid) do
    case Map.pop(holders, pid) do
      {nil, _holders} ->
        state

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        state = %{state | holders: holders}
        if map_size(holders) == 0, do: arm_idle(state), else: state
    end
  end

  @spec arm_idle(State.t()) :: State.t()
  defp arm_idle(state) do
    state = cancel_idle(state)
    %{state | idle_ref: Process.send_after(self(), :idle_timeout, @idle_timeout_ms)}
  end

  @spec cancel_idle(State.t()) :: State.t()
  defp cancel_idle(%State{idle_ref: nil} = state), do: state

  defp cancel_idle(%State{idle_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | idle_ref: nil}
  end

  @spec via(Hyper.Layer.id()) :: GenServer.name()
  defp via(layer_id) do
    {:via, Registry, {Layer.registry(), layer_id}}
  end
end
