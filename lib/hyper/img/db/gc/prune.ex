defmodule Hyper.Img.Db.Gc.Prune do
  @moduledoc """
  The delete step of the layer GC, factored out of the `Gc` server so its
  safety contracts are testable against a real database without the
  cluster-singleton GenServer around them:

    * a missing blob still referenced by an image is *dangling* — reported,
      never deleted;
    * rows younger than `grace_period` are never deleted;
    * the `DELETE` re-checks `NOT EXISTS (image_layers)`, so a reference
      that appeared after the caller's snapshot is skipped, not violated;
    * the shared medium is re-probed before any delete, so a mount that
      vanished mid-page skips the page instead of mass-deleting;
    * `presence/1` maps only a true `:enoent` to `:missing`; any other I/O
      error is `:unknown` and never drives a delete.

  Every query runs at low priority: in a transaction with a capped
  per-statement timeout, so the GC can never pin a backend.
  """

  require Logger
  import Ecto.Query

  alias Hyper.Cfg.Gc, as: Config
  alias Hyper.Img.Db.{Blob, ImageLayer, Repo}
  alias Hyper.Img.Db.Gc.Sweep
  alias Hyper.Node.Layer.Repo, as: LayerRepo

  @doc """
  Act on one page's missing set: re-check the medium is still mounted, split
  dangling (still referenced) from prunable, delete what is out of grace.
  Returns `{pruned, pruned_bytes, dangling}`.
  """
  @spec execute(Config.t(), [Sweep.blob()]) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def execute(_config, []), do: {0, 0, 0}

  def execute(config, missing) do
    case LayerRepo.test_system() do
      :ok ->
        prune_missing(config, missing)

      {:error, reason} ->
        Logger.warning(
          "layer gc: medium became unavailable before pruning (#{inspect(reason)}); " <>
            "skipping #{length(missing)} deletion(s) this page"
        )

        {0, 0, 0}
    end
  end

  @doc """
  Shared-medium presence probe injected into the pure Sweep core.
  Distinguishes a genuine absence (`:enoent` -> prunable) from an I/O error
  (`:unknown` -> never pruned), so a transient NFS hiccup can never drive a
  delete.
  """
  @spec presence(String.t()) :: Sweep.presence()
  def presence(id) do
    case LayerRepo.find_layer(id) do
      {:ok, _path} -> :present
      {:error, :enoent} -> :missing
      {:error, _posix} -> :unknown
    end
  end

  @doc """
  Run a DB operation at low priority: in a transaction with a capped
  per-statement timeout, so it can never pin a backend and yields under
  contention.
  """
  @spec with_low_priority(Config.t(), (-> result)) :: result when result: var
  def with_low_priority(config, fun) do
    timeout = Unit.Time.as_ms(config.timeout)

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

  @doc false
  # Public only for its safety test: the NOT EXISTS re-check guards a race (a
  # reference appearing after the caller snapshotted `referenced_ids`) that
  # cannot be reached deterministically through `execute/2`.
  @spec prune_rows(Config.t(), [String.t()], DateTime.t()) ::
          {non_neg_integer(), non_neg_integer()}
  def prune_rows(_config, [], _cutoff), do: {0, 0}

  def prune_rows(config, ids, cutoff) do
    # `RETURNING size` gives the exact deleted set's count and bytes. The grace
    # cutoff protects freshly-published rows. NOT EXISTS double-guards the FK:
    # even if a reference appeared since we snapshotted `referenced`, that row
    # is skipped rather than raising.
    query =
      from b in Blob,
        as: :b,
        where:
          b.id in ^ids and b.state == :present and b.inserted_at < ^cutoff and
            not exists(from il in ImageLayer, where: il.blob_id == parent_as(:b).id),
        select: b.size

    {count, sizes} = with_low_priority(config, fn -> Repo.delete_all(query) end)
    {count, Enum.sum(sizes)}
  end

  # Prune the missing blobs that no image references; report the rest as dangling.
  @spec prune_missing(Config.t(), [Sweep.blob()]) ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  defp prune_missing(config, missing) do
    ids = Enum.map(missing, fn {id, _size} -> id end)
    referenced = referenced_ids(config, ids)

    {dangling, prunable} =
      Enum.split_with(missing, fn {id, _size} -> MapSet.member?(referenced, id) end)

    report_dangling(dangling)

    cutoff =
      DateTime.add(DateTime.utc_now(), -Unit.Time.as_ms(config.grace_period), :millisecond)

    prunable_ids = Enum.map(prunable, fn {id, _size} -> id end)
    {pruned, pruned_bytes} = prune_rows(config, prunable_ids, cutoff)

    {pruned, pruned_bytes, length(dangling)}
  end

  # Report dangling blobs (file gone, still referenced = data loss) once per
  # page, aggregated, so a broken mount cannot flood the logs one line per blob.
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

  @spec referenced_ids(Config.t(), [String.t()]) :: MapSet.t(String.t())
  defp referenced_ids(config, ids) do
    query = from il in ImageLayer, where: il.blob_id in ^ids, distinct: true, select: il.blob_id
    config |> with_low_priority(fn -> Repo.all(query) end) |> MapSet.new()
  end
end
