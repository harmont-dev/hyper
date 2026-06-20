defmodule Hyper.Img.Db.Gc do
  @moduledoc """
  Cluster-singleton garbage collector that reconciles the `blobs` table against
  the shared medium: a blob marked `:present` whose backing file is gone from the
  medium is a stale row, so the GC prunes it. It runs continuously - sweep after
  sweep - so the database keeps reflecting what the medium actually holds.

  ## Why a singleton, and how it restarts cleanly

  Every node runs this process, but only one is *active* at a time: each contends
  for the `{:singleton, :layer_gc}` key in the `Hyper.Cluster.Routing` Horde
  registry. The winner collects; the rest stand by and re-contend every
  `acquire_interval_ms`. When the active node (or process) dies its registration
  drops out of the DeltaCRDT, and the next standby retry takes over - so GC
  resumes within one acquire interval without a Horde.DynamicSupervisor (which the
  cluster deliberately avoids to prevent ghost restarts). Running once cluster-wide
  also keeps two nodes from racing to delete the same rows.

  ## How it walks the database (low priority)

  It pages through `blobs` by keyset on the primary key
  (`Hyper.Img.Db.Blob.scan_present_after/2`), never `SELECT *`, so a huge table
  cannot blow up the node. To stay out of the way of real traffic it runs at low
  priority: small pages, a pause between them, and every DB statement runs inside a
  transaction that first sets a short `statement_timeout`, so a GC query can never
  pin a backend. The DB connection is released between pages while the slow
  per-row medium check (NFS) happens outside any transaction.

  Before every page it guards on `Hyper.Node.Layer.Repo.test_system/0`: if the
  medium is not mounted it reschedules without querying, so a node with no shared
  medium (dev, test) stays completely inert. Database errors during a sweep are
  caught and retried rather than crash-looping the supervisor.

  ## What it prunes, and what it refuses to

  A `:present` blob whose file is absent from the medium and which **no image
  references** is deleted (`DELETE` guarded by a `NOT EXISTS` against
  `image_layers`, so it can never violate the FK). A missing-file blob that is
  still referenced by an image is a *dangling reference* - genuine data loss the
  GC cannot fix by deleting (the FK would block it, and the image is already
  broken). Those are left in place and reported loudly.

  ## Telemetry

    * `[:hyper, :img, :db, :gc, :sweep, :start]` - measurements `%{}`,
      metadata `%{node: node()}`
    * `[:hyper, :img, :db, :gc, :sweep, :stop]` - measurements
      `%{scanned, present, missing, pruned, pruned_bytes, dangling}`,
      metadata `%{node: node()}`
    * `[:hyper, :img, :db, :gc, :pruned]` - per page; measurements
      `%{count, bytes}`, metadata `%{node: node()}`
    * `[:hyper, :img, :db, :gc, :dangling]` - per dangling blob; measurements
      `%{size}`, metadata `%{blob_id}`
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Hyper.Cluster.Routing
  alias Hyper.Img.Db.{Blob, ImageLayer, Repo}
  alias Hyper.Img.Db.Gc.Sweep
  alias Hyper.Node.Layer.Repo, as: LayerRepo

  @singleton_key {:singleton, :layer_gc}

  @defaults [
    # Low priority: small pages and a pause between them.
    batch_size: 200,
    batch_pause_ms: 100,
    # Continuous: short rest between completed sweeps, not a long idle.
    sweep_interval_ms: 60_000,
    # How often a standby retries to become active.
    acquire_interval_ms: 5_000,
    # Backoff before retrying after the medium or the database is unavailable.
    retry_ms: 60_000,
    # Cap on each GC DB statement so it can never pin a backend.
    statement_timeout_ms: 5_000
  ]

  defstruct [:cfg, role: :standby, sweep: nil, last_sweep: nil]

  @type t :: %__MODULE__{
          cfg: keyword(),
          role: :active | :standby,
          sweep: Sweep.t() | nil,
          last_sweep: Sweep.t() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Local role + last completed sweep, for introspection on this node."
  @spec status() :: %{role: :active | :standby, last_sweep: Sweep.t() | nil}
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    cfg =
      @defaults
      |> Keyword.merge(Application.get_env(:hyper, __MODULE__, []))
      |> Keyword.merge(opts)

    {:ok, %__MODULE__{cfg: cfg}, {:continue, :acquire}}
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
    emit([:sweep, :start], %{}, %{node: node()})
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
          e ->
            Logger.warning(
              "layer gc: database error during sweep (#{Exception.message(e)}); retrying"
            )

            Process.send_after(self(), :sweep, cfg(state, :retry_ms))
            {:noreply, %{state | sweep: nil}}
        end

      {:error, reason} ->
        Logger.warning("layer gc: shared medium unavailable (#{inspect(reason)}); retrying")
        Process.send_after(self(), :sweep, cfg(state, :retry_ms))
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
        Process.send_after(self(), :acquire, cfg(state, :acquire_interval_ms))
        %{state | role: :standby}
    end
  end

  @spec scan_one_batch(t()) :: t()
  defp scan_one_batch(%__MODULE__{sweep: sweep} = state) do
    limit = cfg(state, :batch_size)
    batch = with_low_priority(state, fn -> Blob.scan_present_after(sweep.cursor, limit) end)
    {sweep, missing} = Sweep.absorb(sweep, batch, &present?/1)

    {pruned, pruned_bytes, dangling} = prune_missing(state, missing)
    sweep = Sweep.record_prune(sweep, pruned, pruned_bytes, dangling)

    if Sweep.continue?(batch, limit) do
      Process.send_after(self(), :scan, cfg(state, :batch_pause_ms))
      %{state | sweep: sweep}
    else
      emit(
        [:sweep, :stop],
        Map.take(sweep, [:scanned, :present, :missing, :pruned, :pruned_bytes, :dangling]),
        %{node: node()}
      )

      Logger.info(
        "layer gc sweep complete: scanned=#{sweep.scanned} present=#{sweep.present} " <>
          "missing=#{sweep.missing} pruned=#{sweep.pruned} (#{sweep.pruned_bytes} bytes) " <>
          "dangling=#{sweep.dangling}"
      )

      Process.send_after(self(), :sweep, cfg(state, :sweep_interval_ms))
      %{state | sweep: nil, last_sweep: sweep}
    end
  end

  # Prune the missing blobs that no image references; report the rest as dangling.
  @spec prune_missing(t(), [Sweep.blob()]) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp prune_missing(_state, []), do: {0, 0, 0}

  defp prune_missing(state, missing) do
    ids = Enum.map(missing, fn {id, _size} -> id end)
    referenced = referenced_ids(state, ids)

    {dangling, prunable} =
      Enum.split_with(missing, fn {id, _size} -> MapSet.member?(referenced, id) end)

    Enum.each(dangling, fn {id, size} ->
      Logger.error(
        "layer gc: blob #{id} missing from medium but still referenced by an image " <>
          "(#{size} bytes); leaving in place"
      )

      emit([:dangling], %{size: size}, %{blob_id: id})
    end)

    pruned_bytes = prunable |> Enum.map(fn {_id, size} -> size end) |> Enum.sum()
    prunable_ids = Enum.map(prunable, fn {id, _size} -> id end)
    pruned = prune_rows(state, prunable_ids, pruned_bytes)

    {pruned, pruned_bytes, length(dangling)}
  end

  @spec prune_rows(t(), [String.t()], non_neg_integer()) :: non_neg_integer()
  defp prune_rows(_state, [], _bytes), do: 0

  defp prune_rows(state, ids, bytes) do
    # NOT EXISTS double-guards the FK: even if a reference appeared since we
    # snapshotted `referenced`, the row is simply skipped rather than raising.
    query =
      from b in Blob,
        as: :b,
        where:
          b.id in ^ids and b.state == :present and
            not exists(from il in ImageLayer, where: il.blob_id == parent_as(:b).id)

    {count, _} = with_low_priority(state, fn -> Repo.delete_all(query) end)
    emit([:pruned], %{count: count, bytes: bytes}, %{node: node()})
    count
  end

  @spec referenced_ids(t(), [String.t()]) :: MapSet.t(String.t())
  defp referenced_ids(state, ids) do
    query = from il in ImageLayer, where: il.blob_id in ^ids, distinct: true, select: il.blob_id
    state |> with_low_priority(fn -> Repo.all(query) end) |> MapSet.new()
  end

  # Run a DB operation at low priority: in a transaction whose statement_timeout
  # is capped, so it can never pin a backend and yields under contention.
  @spec with_low_priority(t(), (-> result)) :: result when result: var
  defp with_low_priority(state, fun) do
    timeout = cfg(state, :statement_timeout_ms)

    {:ok, result} =
      Repo.transaction(fn ->
        _ =
          Repo.query!("SELECT set_config('statement_timeout', $1, true)", [
            Integer.to_string(timeout)
          ])

        fun.()
      end)

    result
  end

  # Shared-medium presence probe injected into the pure Sweep core.
  @spec present?(String.t()) :: boolean()
  defp present?(id), do: match?({:ok, _path}, LayerRepo.find_layer(id))

  @spec emit([atom()], map(), map()) :: :ok
  defp emit(suffix, measurements, metadata) do
    :telemetry.execute([:hyper, :img, :db, :gc | suffix], measurements, metadata)
  end

  @spec cfg(t(), atom()) :: term()
  defp cfg(%__MODULE__{cfg: cfg}, key), do: Keyword.fetch!(cfg, key)
end
