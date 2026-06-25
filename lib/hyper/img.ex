defmodule Hyper.Img do
  @moduledoc """
  A content-addressed image: an ordered stack of layers, and the entry point for
  putting one into the cluster.

  `create/2` ingests a prepared image file -- e.g. the ext4 rootfs produced by
  `Hyper.Img.OciLoader` -- into the shared media store and the image database. It
  content-addresses the file (sha256 of its bytes = the image id), publishes it
  into `Hyper.Config.layer_dir/0` at `layer_<id>.img`, then records it as a
  one-layer base image (`blobs` + `images` + `image_layers`). Producers of image
  files stay decoupled from the store and DB: they hand a path to `create/2`.
  """

  use OpenTelemetryDecorator

  require Logger

  alias Hyper.Config
  alias Hyper.Img.Db.{Blob, Image, ImageLayer, Repo}

  @type id :: String.t()

  # `Ecto.Multi` is an opaque struct; building it through the pipe trips
  # dialyzer's opacity check (a known Ecto false positive), so silence it for the
  # one function that assembles a Multi.
  @dialyzer {:no_opaque, record: 3}

  @doc """
  Ingest the image file at `path` into the cluster and return its
  content-addressed id.

  Content-addresses `path` (sha256 of its bytes = the id), publishes it into the
  media store at `layer_<id>.img`, and records it as a one-layer base image. The
  file at `path` is consumed -- moved into the store on success, removed on
  failure -- so the caller hands off ownership.

  `opts[:label]` sets the human-readable `images.label` (defaults to the basename
  of `path`).

  Idempotent: creating identical bytes again is a no-op that returns the same id.
  """
  @spec create(Path.t(), keyword()) :: {:ok, id()} | {:error, term()}
  @decorate with_span("Hyper.Img.create", include: [:path, :label])
  def create(path, opts \\ []) do
    label = Keyword.get(opts, :label, Path.basename(path))

    with {:ok, %File.Stat{size: size}} <- File.stat(path),
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
    File.mkdir_p!(Config.layer_dir())
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
  defp final_path(id), do: Path.join(Config.layer_dir(), "layer_#{id}.img")

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
      |> Ecto.Multi.insert(
        :image,
        Image.changeset(%Image{}, %{id: id, label: label}),
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
end
