defmodule Hyper.Img.Db.Lease do
  @moduledoc """
  A single running VM's claim on an image (and transitively, every blob in that
  image's chain).
 
    * take a lease  -> insert a row        (your "increment, before starting the VM")
    * release       -> delete the row      (your "decrement, when done")
    * heartbeat     -> bump expires_at      (keeps a live VM's claim fresh)
 
  Because the claim is owned and expiring, a node that dies mid-VM does not leak a
  reference — its lease simply lapses, and the blob becomes deletable again without
  anyone running the missing decrement.
  """
  use Ecto.Schema
  import Ecto.Changeset
 
  alias Hyper.Img.Db.Image
 
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "leases" do
    field :node_id, :string
    field :vm_id, :string
    field :expires_at, :utc_datetime_usec
 
    belongs_to :image, Image,
      foreign_key: :image_id,
      references: :id,
      type: :string
 
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
 
  def changeset(lease, attrs) do
    lease
    |> cast(attrs, [:image_id, :node_id, :vm_id, :expires_at])
    |> validate_required([:image_id, :node_id, :vm_id, :expires_at])
    |> foreign_key_constraint(:image_id)
    |> unique_constraint([:node_id, :vm_id],
      name: :leases_node_id_vm_id_index
    )
  end

  @doc """
  Take a lease on the given image, bumping it if one already exists.
  """
  def bump(image_id, node_id, vm_id, ttl_seconds) do
  end

  @doc """
  Release the lease issued to the given node_id and the given vm_id. Since each VM only ever uses
  one image, it is not necessary to specify the image id.
  """
  def release(node_id, vm_id) do
  end

  @doc """
  Reap the expired leases. This is mostly implemented to clean up the database, but does nothing
  outside of that.
  """
  def reap_expired() do
  end
end
