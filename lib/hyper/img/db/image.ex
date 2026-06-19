defmodule Hyper.Img.Db.Image do
  @moduledoc """
  A derivation - e.g. `P' = P + L`. It is resolved at mount time into an
  ordered set of blobs via its `image_layers`. "P'" is a node in the lineage
  graph, never a stored file.
  """
  use Ecto.Schema
  import Ecto.Changeset
 
  alias Hyper.Img.Db.{ImageLayer, Lease}
 
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
    |> validate_required([:id, :sectors])
    |> validate_number(:sectors, greater_than: 0)
    |> cast_assoc(:layers, with: &ImageLayer.changeset/2)
    |> unique_constraint(:id, name: :images_pkey)
  end

  @doc "Ordered assembly of image layers necessary to assemble the given layer."
  defp resolve_chain(id) do
    from(l in ImageLayer,
      where: l.id == ^id,
      order_by: [asc: l.position],
      select: %{l.id}
    )
    |> Repo.all()
  end

  @doc """
  Take a lease on this image, bumping it if one already exists.
  """
  def bump_lease(image_id, node_id, vm_id, ttl_seconds) do
  end
end
