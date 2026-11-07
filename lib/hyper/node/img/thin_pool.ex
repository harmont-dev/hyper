defmodule Hyper.Node.Img.ThinPool do
  @moduledoc """
  The node's single dm-thin pool. On start it materialises two sparse backing
  files in `scratch_dir` (metadata + data), attaches them as writable loop
  devices, zeroes the metadata (so the kernel treats it as a fresh pool), and
  creates the `hyper-thinpool` device-mapper pool.

  `create_external/3` provisions a thin volume whose unwritten blocks read
  through to a read-only external origin (the composed image device) and whose
  writes land in the pool - the per-VM writable rootfs. Thin device ids are a
  bump pointer plus a freed-id stack, mirroring `Hyper.Node.Users`.
  """

  use GenServer

  alias Hyper.Cfg.Img, as: ImgConfig
  alias Hyper.SuidHelper
  alias Unit.Information

  use OpenTelemetryDecorator

  @pool_name "hyper-thinpool"
  @data_file "thinpool.data"
  @meta_file "thinpool.meta"

  defmodule State do
    @moduledoc false
    @enforce_keys [:meta_loop]
    defstruct [:meta_loop, next: 0, freed: []]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec create_volume(String.t(), Path.t(), String.t() | nil) ::
          {:ok, %{dev: Path.t(), id: non_neg_integer()}} | {:error, term()}
  @decorate with_span("Hyper.Node.Img.ThinPool.create_volume", include: [:name, :parent])
  def create_volume(name, origin_dev, parent \\ nil) do
    GenServer.call(__MODULE__, {:create_volume, name, origin_dev, parent}, :timer.seconds(30))
  end

  @spec fork_delta(String.t(), Path.t(), Path.t()) ::
          {:ok, %{scanned: non_neg_integer(), written: non_neg_integer()}} | {:error, term()}
  @decorate with_span("Hyper.Node.Img.ThinPool.fork_delta", include: [:parent, :cow])
  def fork_delta(parent, origin, cow) do
    {scratch_id, meta_loop} = GenServer.call(__MODULE__, :reserve_scratch)

    try do
      SuidHelper.ForkDelta.run(@pool_name, meta_loop, parent, scratch_id, origin, cow)
    after
      GenServer.call(__MODULE__, {:release_scratch, scratch_id})
    end
  end

  @doc "Remove thin volume `name` and free its thin device `id`."
  @spec destroy(String.t(), non_neg_integer()) :: :ok
  @decorate with_span("Hyper.Node.Img.ThinPool.destroy", include: [:name, :id])
  def destroy(name, id), do: GenServer.call(__MODULE__, {:destroy, name, id})

  @impl true
  @decorate with_span("Hyper.Node.Img.ThinPool.init")
  def init(_opts) do
    Process.flag(:trap_exit, true)

    with :ok <- File.mkdir_p(Hyper.Cfg.Dirs.scratch_dir()),
         {:ok, meta} <- ensure_backing(@meta_file, ImgConfig.thin_pool_meta_size()),
         {:ok, data} <- ensure_backing(@data_file, ImgConfig.thin_pool_data_size()),
         {:ok, _pool_dev, meta_loop} <-
           SuidHelper.Thin.create_pool(@pool_name, meta, data, ImgConfig.thin_block_sectors(), 0) do
      {:ok, %State{meta_loop: meta_loop}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create_volume, name, origin_dev, parent}, _from, state) do
    {id, state} = id_alloc(state)

    case SuidHelper.Thin.create_volume(@pool_name, id, name, origin_dev, parent) do
      {:ok, dev} -> {:reply, {:ok, %{dev: dev, id: id}}, state}
      {:error, _} = err -> {:reply, err, id_free(state, id)}
    end
  end

  @impl true
  def handle_call(:reserve_scratch, _from, state) do
    {id, state} = id_alloc(state)
    {:reply, {id, state.meta_loop}, state}
  end

  @impl true
  def handle_call({:release_scratch, id}, _from, state), do: {:reply, :ok, id_free(state, id)}

  @impl true
  def handle_call({:destroy, name, id}, _from, state) do
    _ = SuidHelper.Thin.destroy(@pool_name, name)
    {:reply, :ok, id_free(state, id)}
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
  def terminate(_reason, _state) do
    _ = SuidHelper.Dmsetup.remove(@pool_name)
    :ok
  end

  @doc false
  @spec id_alloc(map()) :: {non_neg_integer(), map()}
  def id_alloc(%{freed: [id | rest]} = s), do: {id, %{s | freed: rest}}
  def id_alloc(%{next: n} = s), do: {n, %{s | next: n + 1}}

  @doc false
  @spec id_free(map(), non_neg_integer()) :: map()
  def id_free(%{freed: freed} = s, id), do: %{s | freed: [id | freed]}

  # Create a sparse file of `size` if absent; reuse it if already present.
  @spec ensure_backing(String.t(), Information.t()) :: {:ok, Path.t()} | {:error, term()}
  defp ensure_backing(file, size) do
    path = Path.join(Hyper.Cfg.Dirs.scratch_dir(), file)

    case File.open(path, [:write, :read]) do
      {:ok, io} ->
        try do
          {:ok, _} = :file.position(io, Information.as_bytes(size))
          :ok = :file.truncate(io)
          {:ok, path}
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, {:backing_file, file, reason}}
    end
  end
end
