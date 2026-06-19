defmodule Hyper.Img.Db.ImageLayer do
  @moduledoc """
  One rung of an image's assembly chain. `position` 0 is the base blob; ascending
  positions are deltas applied on top (each a dm-snapshot COW store over the layer
  below). Selecting all rows for an image ordered by `position` yields exactly the
  ordered blob list and params needed to emit the dmsetup tables.
 
  Insert-only: chains are never edited, only created. The reverse index on
  `blob_id` answers "which images reference this blob" for the delete check, and
  the FK's ON DELETE RESTRICT enforces "can't drop a blob a layer still needs."
  """
  use Ecto.Schema
  import Ecto.Changeset
 
  alias Hyper.Img.Db.{Blob, Image}
 
  @primary_key false
  schema "image_layers" do
    field :position, :integer
 
    belongs_to :image, Image,
      foreign_key: :image_id,
      references: :id,
      type: :string
 
    belongs_to :blob, Blob,
      foreign_key: :blob_id,
      references: :id,
      type: :string
  end
 
  def changeset(layer, attrs) do
    layer
    |> cast(attrs, [:image_id, :position, :blob_id])
    |> validate_required([:position, :blob_id])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:blob_id)
    |> unique_constraint([:image_id, :position],
      name: :image_layers_image_id_position_index
    )
  end
end
