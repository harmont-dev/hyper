defmodule Hyper.Img.Db.Blob do
  @moduledoc """
  An immutable, content-addressed leaf object stored on NFS — a base (`P.img`) or
  a delta (`L.img`). The `id` is both primary key and identity, so inserts are
  conflict-free: two nodes publishing the same bytes write the same row.

  The only field that ever changes is `state`, flipped to `:deleting` as a tombstone
  during a coordinated delete so no new lease can be taken against it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "blobs" do
    field :kind, Ecto.Enum, values: [:base, :delta]
    field :state, Ecto.Enum, values: [:present, :deleting], default: :present

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(blob, attrs) do
    blob
    |> cast(attrs, [:id, :kind, :state])
    |> validate_required([:id, :kind])
    |> unique_constraint(:id, name: :blobs_pkey)
  end
end
