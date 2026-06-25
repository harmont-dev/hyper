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

  alias Hyper.Node.Config.Img, as: ImgConfig
  alias Hyper.SuidHelper
  alias Unit.Information

  use OpenTelemetryDecorator

  @pool_name "hyper-thinpool"
  @data_file "thinpool.data"
  @meta_file "thinpool.meta"

  defmodule State do
    @moduledoc false
    @enforce_keys [:pool_dev, :meta_loop, :data_loop]
    defstruct [:pool_dev, :meta_loop, :data_loop, next: 0, freed: []]
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Provision a thin volume of `sectors` over read-only `origin_dev`."
  @spec create_external(String.t(), Path.t(), pos_integer()) ::
          {:ok, %{dev: Path.t(), id: non_neg_integer()}} | {:error, term()}
  @decorate with_span("Hyper.Node.Img.ThinPool.create_external", include: [:name])
  def create_external(name, origin_dev, sectors) do
    GenServer.call(__MODULE__, {:create_external, name, origin_dev, sectors})
  end

  @doc "Remove thin volume `name` and free its thin device `id`."
  @spec destroy(String.t(), non_neg_integer()) :: :ok
  @decorate with_span("Hyper.Node.Img.ThinPool.destroy", include: [:name, :id])
  def destroy(name, id), do: GenServer.call(__MODULE__, {:destroy, name, id})

  @impl true
  @decorate with_span("Hyper.Node.Img.ThinPool.init")
  def init(_opts) do
    Process.flag(:trap_exit, true)

    with :ok <- File.mkdir_p(Hyper.Config.scratch_dir()),
         {:ok, meta} <- ensure_backing(@meta_file, ImgConfig.thin_pool_meta_size()),
         {:ok, data} <- ensure_backing(@data_file, ImgConfig.thin_pool_data_size()),
         :ok <- zero_metadata(meta),
         {:ok, meta_loop} <- SuidHelper.Losetup.attach_rw(meta),
         {:ok, data_loop} <- SuidHelper.Losetup.attach_rw(data),
         sectors = div(Information.as_bytes(ImgConfig.thin_pool_data_size()), 512),
         {:ok, pool_dev} <-
           SuidHelper.Dmsetup.create_thin_pool(
             @pool_name,
             meta_loop,
             data_loop,
             sectors,
             ImgConfig.thin_block_sectors(),
             0
           ) do
      {:ok, %State{pool_dev: pool_dev, meta_loop: meta_loop, data_loop: data_loop}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create_external, name, origin_dev, sectors}, _from, state) do
    {id, state} = id_alloc(state)

    with :ok <- SuidHelper.Dmsetup.message(@pool_name, "create_thin #{id}"),
         {:ok, dev} <-
           SuidHelper.Dmsetup.create_thin_external(name, state.pool_dev, id, sectors, origin_dev) do
      {:reply, {:ok, %{dev: dev, id: id}}, state}
    else
      {:error, reason} ->
        _ = SuidHelper.Dmsetup.message(@pool_name, "delete #{id}")
        {:reply, {:error, reason}, id_free(state, id)}
    end
  end

  @impl true
  def handle_call({:destroy, name, id}, _from, state) do
    _ = SuidHelper.Dmsetup.remove(name)
    _ = SuidHelper.Dmsetup.message(@pool_name, "delete #{id}")
    {:reply, :ok, id_free(state, id)}
  end

  @impl true
  def terminate(_reason, state) do
    _ = SuidHelper.Dmsetup.remove(@pool_name)
    _ = SuidHelper.Losetup.detach(state.data_loop)
    _ = SuidHelper.Losetup.detach(state.meta_loop)
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
    path = Path.join(Hyper.Config.scratch_dir(), file)

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

  # Wipe the metadata header so the kernel treats the pool as freshly created.
  @spec zero_metadata(Path.t()) :: :ok | {:error, term()}
  defp zero_metadata(path) do
    case File.open(path, [:write, :read, :binary], fn io -> IO.binwrite(io, <<0::4096*8>>) end) do
      {:ok, :ok} -> :ok
      {:ok, other} -> other
      {:error, reason} -> {:error, {:zero_metadata, reason}}
    end
  end
end
