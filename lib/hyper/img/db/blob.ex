defmodule Hyper.Img.Db.Blob do
  @moduledoc """
  An immutable, content-addressed leaf object stored on NFS - a base (`P.img`) or
  a delta (`L.img`). The `id` is both primary key and identity, so inserts are
  conflict-free: two nodes publishing the same bytes write the same row.

  The only field that ever changes is `state`, flipped to `:deleting` as a tombstone
  during a coordinated delete so no new lease can be taken against it.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query
  alias Hyper.Img.Db.Repo

  @type t :: %__MODULE__{}

  @primary_key {:id, :string, autogenerate: false}
  schema "blobs" do
    field :kind, Ecto.Enum, values: [:base, :delta]
    field :state, Ecto.Enum, values: [:present, :deleting], default: :present
    field :size, :integer

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(blob, attrs) do
    blob
    |> cast(attrs, [:id, :kind, :state, :size])
    |> validate_required([:id, :kind, :size])
    |> validate_number(:size, greater_than_or_equal_to: 0)
    |> unique_constraint(:id, name: :blobs_pkey)
  end

  @doc "Keyset page of `{id, size}` for `:present` blobs after `after_id` (nil to start), ordered by id."
  @spec present_after(String.t() | nil, pos_integer()) :: [{String.t(), non_neg_integer()}]
  def present_after(after_id, limit) when is_integer(limit) and limit > 0 do
    base =
      from b in __MODULE__,
        where: b.state == :present,
        order_by: [asc: b.id],
        limit: ^limit,
        select: {b.id, b.size}

    query =
      case after_id do
        nil -> base
        id when is_binary(id) -> from b in base, where: b.id > ^id
      end

    Repo.all(query)
  end
end
