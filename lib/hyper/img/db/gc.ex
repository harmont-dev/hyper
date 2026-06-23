defmodule Hyper.Img.Db.Gc do
  @moduledoc """
  Cluster-singleton garbage collector that reconciles the `blobs` table against
  the shared medium: a `:present` blob whose backing file is gone is a stale row
  and is pruned. Runs continuously, one keyset page at a time.

  Deletes are irreversible, so a blob is pruned only when all of these agree it is
  really gone:

    1. **Errno discrimination** - `Hyper.Node.Layer.Repo.find_layer/1` reports
       `:enoent` only for a true absence; any other I/O error (NFS `ESTALE`/`EIO`,
       a vanished mount) is treated as `:unknown` and never pruned.
    2. **Mount re-check** - `test_system/0` is re-checked after a page's probes and
       before its deletes, so a mount that drops mid-page can't trigger a mass
       delete.
    3. **Grace period** - rows younger than `grace_period` are never deleted, so
       a blob mid-publish (row present, file not finished) is safe.

  The `DELETE` is also guarded by `NOT EXISTS` against `image_layers`, so it can
  never violate the FK. A missing-file blob still referenced by an image is a
  *dangling reference* (data loss the GC can't fix) - left in place and reported,
  never deleted.

  **Publish contract:** write a layer's file to the medium before inserting its
  `blobs` row (ideally write-temp then atomic rename); the grace period is
  insurance, not a substitute.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Hyper.Cluster.Routing
  alias Hyper.Img.Db.{Blob, ImageLayer, Repo}
  alias Hyper.Img.Db.Gc.{Config, Sweep}
  alias Hyper.Node.Layer.Repo, as: LayerRepo

  @singleton_key {:singleton, :layer_gc}

  defstruct [:config, role: :standby, sweep: nil, last_sweep: nil]

  @type t :: %__MODULE__{
          config: Config.t(),
          role: :active | :standby,
          sweep: Sweep.State.t() | nil,
          last_sweep: Sweep.State.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Local role + last completed sweep, for introspection on this node."
  @spec status() :: %{role: :active | :standby, last_sweep: Sweep.State.t() | nil}
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    config = Keyword.get(opts, :config) || Config.load()

    if config.enabled do
      {:ok, %__MODULE__{config: config}, {:continue, :acquire}}
    else
      Logger.info("layer gc: disabled by config; not starting")
      :ignore
    end
  end

  @impl true
  def handle_continue(:acquire, state), do: {:noreply, acquire(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{role: state.role, last_sweep: state.last_sweep}, state}
  end

  @impl true
  def handle_info(:acquire, %__MODULE__{role: :standby} = state) do
    {:noreply, acquire(state)}
  end

  # A late acquire tick after we already won: ignore.
  def handle_info(:acquire, state), do: {:noreply, state}

  def handle_info(:sweep, %__MODULE__{role: :active, sweep: nil} = state) do
    send(self(), :scan)
    {:noreply, %{state | sweep: Sweep.new()}}
  end

  # A sweep is already running; drop this duplicate :sweep (e.g. a stale
  # retry timer that overlapped the active sweep).
  def handle_info(:sweep, %__MODULE__{role: :active} = state), do: {:noreply, state}

  def handle_info(:scan, %__MODULE__{role: :active} = state) do
    case LayerRepo.test_system() do
      :ok ->
        try do
          {:noreply, scan_one_batch(state)}
        rescue
          # Only swallow database unavailability (incl. statement_timeout aborts)
          # and retry; let any other exception crash so a real bug surfaces.
          e in [Postgrex.Error, Exqlite.Error, DBConnection.ConnectionError] ->
            Logger.warning(
              "layer gc: database unavailable during sweep (#{Exception.message(e)}); retrying"
            )

            Process.send_after(self(), :sweep, Unit.Time.as_ms(state.config.retry))
            {:noreply, %{state | sweep: nil}}
        end

      {:error, reason} ->
        Logger.warning("layer gc: shared medium unavailable (#{inspect(reason)}); retrying")
        Process.send_after(self(), :sweep, Unit.Time.as_ms(state.config.retry))
        {:noreply, %{state | sweep: nil}}
    end
  end

  # Ignore any unexpected message (stale :sweep/:scan timers from a previous
  # role, monitor noise, etc.) rather than crashing an in-flight sweep.
  def handle_info(_msg, state), do: {:noreply, state}

  ## Internals

  @spec acquire(t()) :: t()
  defp acquire(state) do
    case Horde.Registry.register(Routing.name(), @singleton_key, nil) do
      {:ok, _pid} ->
        Logger.info("layer gc: this node is now the active collector")
        send(self(), :sweep)
        %{state | role: :active}

      {:error, {:already_registered, _pid}} ->
        Process.send_after(self(), :acquire, Unit.Time.as_ms(state.config.acquire_interval))
        %{state | role: :standby}
    end
  end

  @spec scan_one_batch(t()) :: t()
  defp scan_one_batch(%__MODULE__{sweep: sweep} = state) do
    limit = state.config.batch_size

    batch =
      Repo.with_low_priority(Unit.Time.as_ms(state.config.statement_timeout), fn ->
        Blob.present_after(sweep.cursor, limit)
      end)

    {sweep, missing} = Sweep.absorb(sweep, batch, &presence/1)

    {pruned, pruned_bytes, dangling} = maybe_prune(state, missing)
    sweep = Sweep.record_prune(sweep, pruned, pruned_bytes, dangling)

    if Sweep.continue?(batch, limit) do
      Process.send_after(self(), :scan, Unit.Time.as_ms(state.config.batch_pause))
      %{state | sweep: sweep}
    else
      Logger.info(
        "layer gc sweep complete: scanned=#{sweep.scanned} present=#{sweep.present} " <>
          "missing=#{sweep.missing} unknown=#{sweep.unknown} pruned=#{sweep.pruned} " <>
          "(#{sweep.pruned_bytes} bytes) dangling=#{sweep.dangling}"
      )

      Process.send_after(self(), :sweep, Unit.Time.as_ms(state.config.sweep_interval))
      %{state | sweep: nil, last_sweep: sweep}
    end
  end

  # Re-check the medium is still mounted before acting on a page's "missing"
  # set. If the whole mount vanished mid-page, every probe read as gone - skip
  # the deletions rather than wipe a page of live rows.
  @spec maybe_prune(t(), [Sweep.blob()]) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp maybe_prune(_state, []), do: {0, 0, 0}

  defp maybe_prune(state, missing) do
    case LayerRepo.test_system() do
      :ok ->
        prune_missing(state, missing)

      {:error, reason} ->
        Logger.warning(
          "layer gc: medium became unavailable before pruning (#{inspect(reason)}); " <>
            "skipping #{length(missing)} deletion(s) this page"
        )

        {0, 0, 0}
    end
  end

  # Prune the missing blobs that no image references; report the rest as dangling.
  @spec prune_missing(t(), [Sweep.blob()]) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp prune_missing(state, missing) do
    ids = Enum.map(missing, fn {id, _size} -> id end)
    referenced = referenced_ids(state, ids)

    {dangling, prunable} =
      Enum.split_with(missing, fn {id, _size} -> MapSet.member?(referenced, id) end)

    report_dangling(dangling)

    cutoff =
      DateTime.add(DateTime.utc_now(), -Unit.Time.as_ms(state.config.grace_period), :millisecond)

    prunable_ids = Enum.map(prunable, fn {id, _size} -> id end)
    {pruned, pruned_bytes} = prune_rows(state, prunable_ids, cutoff)

    {pruned, pruned_bytes, length(dangling)}
  end

  @spec prune_rows(t(), [String.t()], DateTime.t()) :: {non_neg_integer(), non_neg_integer()}
  defp prune_rows(_state, [], _cutoff), do: {0, 0}

  defp prune_rows(state, ids, cutoff) do
    # `RETURNING size` gives the exact deleted set's count and bytes. The grace
    # cutoff protects freshly-published rows. NOT EXISTS double-guards the FK:
    # even if a reference appeared since we snapshotted `referenced`, that row is
    # skipped rather than raising.
    query =
      from b in Blob,
        as: :b,
        where:
          b.id in ^ids and b.state == :present and b.inserted_at < ^cutoff and
            not exists(from il in ImageLayer, where: il.blob_id == parent_as(:b).id),
        select: b.size

    {count, sizes} =
      Repo.with_low_priority(Unit.Time.as_ms(state.config.statement_timeout), fn ->
        Repo.delete_all(query)
      end)

    {count, Enum.sum(sizes)}
  end

  # Report dangling blobs (file gone, still referenced = data loss) once per page,
  # aggregated, so a broken mount cannot flood the logs one line per blob.
  @spec report_dangling([Sweep.blob()]) :: :ok
  defp report_dangling([]), do: :ok

  defp report_dangling(dangling) do
    count = length(dangling)
    bytes = dangling |> Enum.map(fn {_id, size} -> size end) |> Enum.sum()
    sample = dangling |> Enum.take(10) |> Enum.map(fn {id, _size} -> id end)

    Logger.error(
      "layer gc: #{count} blob(s) missing from medium but still referenced by an image " <>
        "(#{bytes} bytes total); leaving in place. sample=#{inspect(sample)}"
    )
  end

  @spec referenced_ids(t(), [String.t()]) :: MapSet.t(String.t())
  defp referenced_ids(state, ids) do
    query = from il in ImageLayer, where: il.blob_id in ^ids, distinct: true, select: il.blob_id

    Repo.with_low_priority(Unit.Time.as_ms(state.config.statement_timeout), fn ->
      Repo.all(query)
    end)
    |> MapSet.new()
  end

  # Shared-medium presence probe injected into the pure Sweep core. Distinguishes
  # a genuine absence (`:enoent` -> prunable) from an I/O error (`:unknown` ->
  # never pruned), so a transient NFS hiccup can never drive a delete.
  @spec presence(String.t()) :: Sweep.presence()
  defp presence(id) do
    case LayerRepo.find_layer(id) do
      {:ok, _path} -> :present
      {:error, :enoent} -> :missing
      {:error, _posix} -> :unknown
    end
  end
end
