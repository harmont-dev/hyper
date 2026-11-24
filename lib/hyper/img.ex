defmodule Hyper.Img do
  @moduledoc """
  A content-addressed image: an ordered stack of layers, and the entry point for
  putting one into the cluster.

  `create/2` ingests a prepared image file -- e.g. the ext4 rootfs produced by
  `Hyper.Img.OciLoader` -- into the shared media store and the image database. It
  content-addresses the file (sha256 of its bytes = the image id), publishes it
  into `Hyper.Cfg.Dirs.layer_dir/0` at `layer_<id>.img`, then records it as a
  one-layer base image (`blobs` + `images` + `image_layers`). Producers of image
  files stay decoupled from the store and DB: they hand a path to `create/2`.

  `delete/1` is the inverse: it drops an image no VM leases, then every blob of
  its chain that no other image still references, file and row.
  """

  use OpenTelemetryDecorator

  import Ecto.Query

  require Logger

  alias Hyper.Img.Db.{Blob, Image, ImageLayer, Lease, Repo}

  @type id :: String.t()

  # `Ecto.Multi` is an opaque struct; building it through the pipe trips
  # dialyzer's opacity check (a known Ecto false positive), so silence it for the
  # one function that assembles a Multi.
  @dialyzer {:no_opaque, record: 3, record_derived: 3}

  @doc """
  Ingest the image file at `path` into the cluster and return its
  content-addressed id.

  Content-addresses `path` (sha256 of its bytes = the id), publishes it into the
  media store at `layer_<id>.img`, and records it as a one-layer base image. The
  file at `path` is consumed -- moved into the store on success, removed on
  failure -- so the caller hands off ownership.

  `opts[:label]` sets the human-readable `images.label` (defaults to the basename
  of `path`). A label Postgres `text` cannot store (NUL, invalid UTF-8) is
  `{:error, :bad_label}`, refused before anything is published.

  Idempotent: creating identical bytes again is a no-op that returns the same id.
  """
  @spec create(Path.t(), keyword()) :: {:ok, id()} | {:error, term()}
  @decorate with_span("Hyper.Img.create", include: [:path, :label])
  def create(path, opts \\ []) do
    label = Keyword.get(opts, :label, Path.basename(path))

    with :ok <- check_label(label),
         {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, id} <- content_id(path),
         {:ok, final, origin} <- publish(path, id),
         :ok <- record_or_rollback(id, label, size, final, origin) do
      {:ok, id}
    else
      {:error, _} = err ->
        _ = File.rm(path)
        err
    end
  end

  @doc """
  The id of the image derived from `parent_img_id` by applying delta blob
  `delta_blob_id`: a digest of the *pair*, so re-publishing the same fork is
  idempotent while identical delta bytes over different parents still get
  distinct image rows.
  """
  @spec derived_image_id(id(), String.t(), Unit.Information.t()) :: id()
  def derived_image_id(parent_img_id, delta_blob_id, device_size) do
    :sha256
    |> :crypto.hash("#{parent_img_id}:#{delta_blob_id}:#{Unit.Information.as_bytes(device_size)}")
    |> Base.encode16(case: :lower)
  end

  @doc """
  The `image_layers` rows of a derived image: the parent's blob chain in order
  at positions `0..n-1`, the delta blob at position `n`.
  """
  @spec derived_layer_rows(id(), [String.t()], String.t()) :: [
          %{image_id: id(), position: non_neg_integer(), blob_id: String.t()}
        ]
  def derived_layer_rows(image_id, parent_blob_ids, delta_blob_id) do
    (parent_blob_ids ++ [delta_blob_id])
    |> Enum.with_index()
    |> Enum.map(fn {blob_id, position} ->
      %{image_id: image_id, position: position, blob_id: blob_id}
    end)
  end

  @doc """
  Ingest the dm-snapshot COW file at `delta_path` as a new delta layer over
  `parent_img_id`, returning the derived image's id. The file is consumed, like
  `create/2`. Idempotent for identical bytes over the same parent.

  `opts[:label]` sets the derived image's label (defaults to the file basename).
  """
  @spec create_derived(id(), Path.t(), Unit.Information.t(), keyword()) ::
          {:ok, id()} | {:error, term()}
  @decorate with_span("Hyper.Img.create_derived", include: [:parent_img_id, :delta_path])
  def create_derived(parent_img_id, delta_path, device_size, opts \\ []) do
    label = Keyword.get(opts, :label, Path.basename(delta_path))

    with {:ok, parent_blob_ids} <- parent_chain(parent_img_id),
         :ok <- holds_parent(parent_img_id, device_size),
         {:ok, %File.Stat{size: size}} <- File.stat(delta_path),
         {:ok, blob_id} <- content_id(delta_path),
         {:ok, final, origin} <- publish(delta_path, blob_id),
         img_id = derived_image_id(parent_img_id, blob_id, device_size),
         :ok <-
           record_derived_or_rollback(
             {img_id, label, device_size},
             {blob_id, size},
             parent_blob_ids,
             {final, origin}
           ) do
      {:ok, img_id}
    else
      {:error, _} = err ->
        _ = File.rm(delta_path)
        err
    end
  end

  @doc """
  Delete image `img_id`: its `images` row, then every blob of its chain that no
  other image references -- the blob's file in the media store, then its row.

  Refused with `{:error, :in_use}` while a VM holds an unexpired lease on the
  image; a lapsed lease is dead, as `Hyper.Img.Db.Lease` defines it. Once the row
  is gone no VM can lease the image, so none can start from it. Images derived
  from `img_id` keep working: the blobs their chains share stay. `{:error,
  :unknown_image}` when no image has that id, so a repeated delete is harmless.

  A blob whose file cannot be removed keeps its row, and the failure is logged:
  a row is never dropped while its bytes may still be on the medium.
  """
  @spec delete(id()) :: :ok | {:error, :in_use | :unknown_image}
  @decorate with_span("Hyper.Img.delete", include: [:img_id])
  def delete(img_id) do
    with {:ok, chain} <- forget(img_id) do
      Enum.each(chain, &drop_blob/1)
    end
  end

  # The row lock serialises this against `Lease.bump/3`: a new lease's foreign-key
  # check waits on it, then finds the image gone. A lease taken first is seen by
  # the check, which runs after the lock is held.
  @spec forget(id()) :: {:ok, [String.t()]} | {:error, :in_use | :unknown_image}
  defp forget(img_id) do
    image = from(i in Image, where: i.id == ^img_id, lock: "FOR UPDATE", select: i.id)
    chain = from(l in ImageLayer, where: l.image_id == ^img_id, select: l.blob_id)

    Repo.transaction(fn ->
      leased =
        from(l in Lease, where: l.image_id == ^img_id and l.expires_at > ^DateTime.utc_now())

      cond do
        Repo.one(image) == nil ->
          Repo.rollback(:unknown_image)

        Repo.exists?(leased) ->
          Repo.rollback(:in_use)

        true ->
          blob_ids = Repo.all(chain)
          {1, _} = Repo.delete_all(from(i in Image, where: i.id == ^img_id))
          blob_ids
      end
    end)
  end

  # Lock the blob before asking whether a layer still references it: the
  # reference check is a later statement, so it sees every layer committed before
  # the lock, and a layer inserted after waits on the lock and then fails its
  # foreign key. `record/3` takes the same lock before it trusts a blob's file.
  # The file goes first: a commit that then fails leaves an unreferenced row
  # with no file, which `Hyper.Img.Db.Gc` prunes.
  @spec drop_blob(String.t()) :: :ok
  defp drop_blob(blob_id) do
    blob = from(b in Blob, where: b.id == ^blob_id, lock: "FOR UPDATE", select: b.id)
    referenced = from(l in ImageLayer, where: l.blob_id == ^blob_id)

    result =
      Repo.transaction(fn ->
        with ^blob_id <- Repo.one(blob),
             false <- Repo.exists?(referenced),
             :ok <- remove_file(final_path(blob_id)) do
          {1, _} = Repo.delete_all(from(b in Blob, where: b.id == ^blob_id))
          :dropped
        else
          nil -> :already_gone
          true -> :shared
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, _outcome} ->
        :ok

      {:error, reason} ->
        Logger.warning("image blob #{blob_id} kept: its file could not be removed: #{reason}")
    end
  end

  @spec remove_file(Path.t()) :: :ok | {:error, File.posix()}
  defp remove_file(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _} = err -> err
    end
  end

  @spec check_label(String.t()) :: :ok | {:error, :bad_label}
  defp check_label(label),
    do: if(Hyper.Img.Db.Repo.storable_text?(label), do: :ok, else: {:error, :bad_label})

  @spec holds_parent(id(), Unit.Information.t()) ::
          :ok
          | {:error, :unknown_image}
          | {:error, {:smaller_than_parent, Unit.Information.t(), Unit.Information.t()}}
  defp holds_parent(parent_img_id, device_size) do
    with {:ok, parent} <- Image.device_size(parent_img_id) do
      if Unit.Information.as_bytes(device_size) >= Unit.Information.as_bytes(parent),
        do: :ok,
        else: {:error, {:smaller_than_parent, device_size, parent}}
    end
  end

  @spec parent_chain(id()) :: {:ok, [String.t()]} | {:error, {:unknown_parent_image, id()}}
  defp parent_chain(parent_img_id) do
    case Image.resolve_chain(parent_img_id) do
      [] -> {:error, {:unknown_parent_image, parent_img_id}}
      blobs -> {:ok, Enum.map(blobs, & &1.id)}
    end
  end

  @spec record_derived_or_rollback(
          {id(), String.t(), Unit.Information.t()},
          {String.t(), non_neg_integer()},
          [String.t()],
          {Path.t(), :created | :reused}
        ) :: :ok | {:error, term()}
  defp record_derived_or_rollback(image, {blob_id, size}, parents, {final, origin}) do
    case record_derived(image, {blob_id, size}, parents) do
      :ok ->
        :ok

      {:error, _} = err ->
        _ = if origin == :created, do: File.rm(final), else: :ok
        err
    end
  end

  # One transaction: delta blob, derived image, and the full chain rows. All
  # idempotent upserts, mirroring record/3.
  @spec record_derived(
          {id(), String.t(), Unit.Information.t()},
          {String.t(), non_neg_integer()},
          [String.t()]
        ) :: :ok | {:error, term()}
  defp record_derived({img_id, label, device_size}, {blob_id, size}, parent_blob_ids) do
    rows = derived_layer_rows(img_id, parent_blob_ids, blob_id)

    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :blob,
        Blob.changeset(%Blob{}, %{id: blob_id, kind: :delta, size: size}),
        on_conflict: :nothing,
        conflict_target: :id
      )
      |> Ecto.Multi.run(:blob_file, fn repo, _changes -> backed(repo, blob_id) end)
      |> Ecto.Multi.insert(
        :image,
        Image.changeset(%Image{}, %{
          id: img_id,
          label: label,
          device_size: Unit.Information.as_bytes(device_size)
        }),
        on_conflict: :nothing,
        conflict_target: :id
      )

    rows
    |> Enum.reduce(multi, fn row, acc ->
      Ecto.Multi.insert(
        acc,
        {:layer, row.position},
        ImageLayer.changeset(%ImageLayer{}, row),
        on_conflict: :nothing,
        conflict_target: [:image_id, :position]
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> :ok
      {:error, step, reason, _changes} -> {:error, {:record_failed, step, reason}}
    end
  end

  # Record the image; if the DB write fails, roll back a file we just created (a
  # reused file pre-existed and may back another image, so leave it).
  @spec record_or_rollback(id(), String.t(), non_neg_integer(), Path.t(), :created | :reused) ::
          :ok | {:error, term()}
  defp record_or_rollback(id, label, size, final, origin) do
    case record(id, label, size) do
      :ok ->
        :ok

      {:error, _} = err ->
        _ = if origin == :created, do: File.rm(final), else: :ok
        err
    end
  end

  # Streaming sha256 of `path`, lowercase hex -- the content address.
  @spec content_id(Path.t()) :: {:ok, id()} | {:error, term()}
  @decorate with_span("Hyper.Img.content_id", include: [:path])
  defp content_id(path) do
    {:ok, Redist.Sha256.file(path)}
  rescue
    e -> {:error, {:hash_failed, Exception.message(e)}}
  end

  # Move `src` into the store at its content-addressed path. If the destination
  # already exists (identical bytes already published), drop `src` and reuse it.
  @spec publish(Path.t(), id()) :: {:ok, Path.t(), :created | :reused} | {:error, term()}
  @decorate with_span("Hyper.Img.publish", include: [:id])
  defp publish(src, id) do
    File.mkdir_p!(Hyper.Cfg.Dirs.layer_dir())
    final = final_path(id)

    if File.exists?(final) do
      Logger.info("image #{id} already present in store; reusing")
      _ = File.rm(src)
      {:ok, final, :reused}
    else
      case place(src, final) do
        {:ok, ^final} -> {:ok, final, :created}
        {:error, _} = err -> err
      end
    end
  end

  # An atomic rename when `src` is on the store's filesystem; a copy-then-drop
  # across filesystems (rename can't cross a mount).
  @spec place(Path.t(), Path.t()) :: {:ok, Path.t()} | {:error, term()}
  defp place(src, final) do
    case File.rename(src, final) do
      :ok ->
        {:ok, final}

      {:error, :exdev} ->
        case File.cp(src, final) do
          :ok ->
            _ = File.rm(src)
            {:ok, final}

          {:error, reason} ->
            _ = File.rm(final)
            {:error, {:publish_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:publish_failed, reason}}
    end
  end

  @spec final_path(id()) :: Path.t()
  defp final_path(id), do: Path.join(Hyper.Cfg.Dirs.layer_dir(), "layer_#{id}.img")

  # Record the base image: one blob, one image (id == blob id), one layer at
  # position 0. All upserts are idempotent so a re-publish of the same bytes is a
  # no-op. The blob is inserted before the layer so the FK is satisfied.
  @spec record(id(), String.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp record(id, label, size) do
    multi =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(
        :blob,
        Blob.changeset(%Blob{}, %{id: id, kind: :base, size: size}),
        on_conflict: :nothing,
        conflict_target: :id
      )
      |> Ecto.Multi.run(:blob_file, fn repo, _changes -> backed(repo, id) end)
      |> Ecto.Multi.insert(
        :image,
        Image.changeset(%Image{}, %{id: id, label: label, device_size: size}),
        on_conflict: :nothing,
        conflict_target: :id
      )
      |> Ecto.Multi.insert(
        :layer,
        ImageLayer.changeset(%ImageLayer{}, %{image_id: id, position: 0, blob_id: id}),
        on_conflict: :nothing,
        conflict_target: [:image_id, :position]
      )

    case Repo.transaction(multi) do
      {:ok, _} -> :ok
      {:error, step, reason, _changes} -> {:error, {:record_failed, step, reason}}
    end
  end

  # The blob row may predate this publish, and `delete/1` may be removing it. Hold
  # the row against `drop_blob/1`'s lock, then check the file is still there, so
  # no image is ever recorded over a blob whose file is gone.
  @spec backed(Ecto.Repo.t(), String.t()) :: {:ok, :present} | {:error, :file_removed}
  defp backed(repo, blob_id) do
    held = from(b in Blob, where: b.id == ^blob_id, lock: "FOR KEY SHARE", select: b.id)

    if repo.one(held) == blob_id and File.exists?(final_path(blob_id)),
      do: {:ok, :present},
      else: {:error, :file_removed}
  end
end
