defmodule Hyper.Node.Img.Server do
  @moduledoc """
  GenServer representing a single active image on this node.

  On start it resolves the image's layer chain, acquires each `Layer.Server`
  (keeping the loop devices mounted), and assembles them into a single read-only
  block device by stacking dm-snapshot targets (base at the bottom, each delta's
  exception store layered on top). `blk_path/1` returns that composed device.

  Reference-counted via process monitors, like `Layer.Server`: holders `acquire/1`
  it; when the last leaves it idle-reaps, removing its dm chain in `terminate/2`
  and releasing its layers (which then unmount once nothing else holds them).
  """

  use GenServer, restart: :temporary
  require Logger

  alias Hyper.Img.Db
  alias Hyper.Node.Layer
  alias Hyper.SuidHelper

  use OpenTelemetryDecorator

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id(),
            layers: [Hyper.Layer.id()],
            dm_names: [String.t()],
            blk_path: Path.t() | nil,
            holders: %{pid() => reference()},
            idle_ref: reference() | nil
          }

    defstruct [:img_id, :blk_path, layers: [], dm_names: [], holders: %{}, idle_ref: nil]
  end

  defmodule Opts do
    @moduledoc "Options for starting an image server."

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id()
          }

    defstruct [:img_id]
  end

  @doc "The ordered layer ids that compose the image managed by `server`."
  @spec layers(GenServer.server()) :: [Hyper.Layer.id()]
  def layers(server), do: GenServer.call(server, :layers)

  @doc "The composed read-only block device path for the image managed by `server`."
  @spec blk_path(GenServer.server()) :: Path.t()
  def blk_path(server), do: GenServer.call(server, :blk_path)

  @doc """
  Take a reference on `server` on behalf of the calling process. The image stays
  assembled until every holder releases (or dies). Idempotent per process.
  """
  @spec acquire(GenServer.server()) :: :ok
  def acquire(server), do: GenServer.call(server, {:acquire, self()})

  @doc "Drop the calling process's reference on `server`."
  @spec release(GenServer.server()) :: :ok
  def release(server), do: GenServer.call(server, {:release, self()})

  @doc "Start an image server for `opts`, registered by image id."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{img_id: img_id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via(img_id))
  end

  @impl true
  @decorate with_span("Hyper.Node.Img.Server.init", include: [:img_id])
  def init(%Opts{img_id: img_id}) do
    Process.flag(:trap_exit, true)
    layer_ids = resolve_layers(img_id)

    with {:ok, loop_paths} <- acquire_layers(layer_ids),
         {:ok, %{blk_path: blk_path, dm_names: dm_names}} <- build_chain(img_id, loop_paths) do
      state = %State{img_id: img_id, layers: layer_ids, dm_names: dm_names, blk_path: blk_path}
      {:ok, arm_idle(state)}
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
  def handle_call(:layers, _from, %State{layers: layers} = state) do
    {:reply, layers, state}
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
    {:noreply, state}
  end

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
  def terminate(_reason, %State{dm_names: dm_names}) do
    # Remove top-down (a snapshot's origin is the device below it). Layers are
    # released automatically when this process exits (Layer.Server monitors us).
    dm_names |> Enum.reverse() |> Enum.each(&remove_quietly/1)
    :ok
  end

  # The ordered layer ids that compose `img_id`, from the image-lineage database.
  @spec resolve_layers(Hyper.Img.id()) :: [Hyper.Layer.id()]
  defp resolve_layers(img_id) do
    img_id
    |> Db.Image.resolve_chain()
    |> Enum.map(& &1.id)
  end

  # Mount-or-reuse each layer, take a reference on it, and collect the loop device
  # paths in order. Stops at the first failure; layers already acquired are
  # released when this process exits.
  @spec acquire_layers([Hyper.Layer.id()]) :: {:ok, [Path.t()]} | {:error, term()}
  defp acquire_layers(layer_ids) do
    layer_ids
    |> Enum.reduce_while({:ok, []}, fn layer_id, {:ok, paths} ->
      with {:ok, pid} <- Layer.Server.for_layer(layer_id),
           :ok <- Layer.Server.acquire(pid) do
        {:cont, {:ok, [Layer.Server.blk_path(pid) | paths]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, _} = err -> err
    end
  end

  # Stack dm-snapshot devices: base loop is the origin, each delta loop is layered
  # on top. Rolls back any devices it created if a later one fails.
  @spec build_chain(Hyper.Img.id(), [Path.t()]) ::
          {:ok, %{blk_path: Path.t(), dm_names: [String.t()]}} | {:error, term()}
  defp build_chain(img_id, [base | deltas]) do
    with {:ok, sectors} <- SuidHelper.Blockdev.device_sectors(base) do
      deltas
      |> Enum.with_index(1)
      |> Enum.reduce_while({:ok, base, []}, fn {cow_dev, idx}, {:ok, origin, names} ->
        name = dm_name(img_id, idx)

        case SuidHelper.Dmsetup.create_snapshot(name, origin, cow_dev, sectors) do
          {:ok, dev} ->
            {:cont, {:ok, dev, [name | names]}}

          {:error, reason} ->
            Enum.each(names, &remove_quietly/1)
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, blk_path, names} -> {:ok, %{blk_path: blk_path, dm_names: Enum.reverse(names)}}
        {:error, _} = err -> err
      end
    end
  end

  @spec dm_name(Hyper.Img.id(), pos_integer()) :: String.t()
  defp dm_name(img_id, idx), do: "hyper-img-#{sanitize(img_id)}-#{idx}"

  @spec sanitize(String.t()) :: String.t()
  defp sanitize(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")

  @spec remove_quietly(String.t()) :: :ok
  defp remove_quietly(name) do
    case SuidHelper.Dmsetup.remove(name) do
      :ok ->
        :ok

      {:error, {errc, out}} ->
        Logger.error("Failed to remove dm device #{name} (exit #{errc}): #{out}")
        :ok
    end
  end

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

  # How long an idle image lingers with no users before it is torn down.
  @idle_grace :timer.seconds(30)

  @spec arm_idle(State.t()) :: State.t()
  defp arm_idle(state) do
    state = cancel_idle(state)

    %{state | idle_ref: Process.send_after(self(), :idle_timeout, @idle_grace)}
  end

  @spec cancel_idle(State.t()) :: State.t()
  defp cancel_idle(%State{idle_ref: nil} = state), do: state

  defp cancel_idle(%State{idle_ref: ref} = state) do
    _ = Process.cancel_timer(ref)
    %{state | idle_ref: nil}
  end

  @spec via(Hyper.Img.id()) :: GenServer.name()
  defp via(img_id), do: {:via, Registry, {Hyper.Node.Img.registry(), img_id}}
end
