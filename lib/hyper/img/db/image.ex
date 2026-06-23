defmodule Hyper.Img.Db.Image do
  @moduledoc """
  A derivation - e.g. `P' = P + L`. It is resolved at mount time into an
  ordered set of blobs via its `image_layers`. "P'" is a node in the lineage
  graph, never a stored file.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Hyper.Img.Db.{ImageLayer, Lease, Repo}
  alias Unit.Information

  @primary_key {:id, :string, autogenerate: false}
  schema "images" do
    field :label, :string

    has_many :layers, ImageLayer,
      foreign_key: :image_id,
      references: :id,
      preload_order: [asc: :position]

    has_many :leases, Lease, foreign_key: :image_id, references: :id

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(image, attrs) do
    image
    |> cast(attrs, [:id, :label])
    |> validate_required([:id])
    |> cast_assoc(:layers, with: &ImageLayer.changeset/2)
    |> unique_constraint(:id, name: :images_pkey)
  end

  @doc "The image's ordered layers as `{blob_id, size}`, base first."
  @spec chain_sizes(String.t()) :: [{String.t(), Unit.Information.t()}]
  def chain_sizes(image_id) do
    image_id
    |> resolve_chain()
    |> Repo.all()
    |> Enum.map(fn blob -> {blob.id, Information.bytes(blob.size)} end)
  end

  @doc "Query for the ordered blobs needed to assemble `image_id`, base (position 0) first."
  @spec resolve_chain(String.t()) :: Ecto.Query.t()
  def resolve_chain(image_id) do
    from l in ImageLayer,
      where: l.image_id == ^image_id,
      join: b in assoc(l, :blob),
      order_by: [asc: l.position],
      select: b
  end
end
