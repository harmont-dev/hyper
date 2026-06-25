defmodule Hyper.Img.Db.Lease do
  @moduledoc """
  A single running VM's claim on an image (and transitively, every blob in that
  image's chain).

    * take a lease  -> insert a row        (your "increment, before starting the VM")
    * release       -> delete the row      (your "decrement, when done")
    * heartbeat     -> bump expires_at      (keeps a live VM's claim fresh)

  Because the claim is owned and expiring, a node that dies mid-VM does not leak a
  reference - its lease simply lapses, and the blob becomes deletable again without
  anyone running the missing decrement.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Hyper.Img.Db.{Image, Repo}

  use OpenTelemetryDecorator

  def default_ttl, do: Unit.Time.s(60)

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
    |> unique_constraint([:node_id, :vm_id], name: :leases_node_id_vm_id_index)
  end

  @doc """
  Take a lease on the given image, bumping its expiry if one already exists.

  Upserts on `(node_id, vm_id)` - the same call both takes a fresh lease and
  heartbeats a live one.
  """
  @spec bump(Hyper.Img.id(), Hyper.Vm.id(), Unit.Time.t()) ::
          {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  @decorate with_span("Hyper.Img.Db.Lease.bump", include: [:image_id, :vm_id])
  def bump(image_id, vm_id, ttl) do
    expires_at = DateTime.add(DateTime.utc_now(), Unit.Time.as_s(ttl), :second)

    %__MODULE__{}
    |> changeset(%{
      image_id: image_id,
      node_id: to_string(node()),
      vm_id: vm_id,
      expires_at: expires_at
    })
    |> Repo.insert(
      on_conflict: [set: [expires_at: expires_at]],
      conflict_target: [:node_id, :vm_id]
    )
  end

  @doc """
  Release the lease issued to the given node_id and the given vm_id. Since each VM only ever uses
  one image, it is not necessary to specify the image id.
  """
  @spec release(Hyper.Vm.id()) :: :ok
  @decorate with_span("Hyper.Img.Db.Lease.release", include: [:vm_id])
  def release(vm_id) do
    query = from(l in __MODULE__, where: l.node_id == ^to_string(node()) and l.vm_id == ^vm_id)
    {_count, _} = Repo.delete_all(query)
    :ok
  end

  @doc """
  Reap the expired leases. This is mostly implemented to clean up the database, but does nothing
  outside of that. Returns the number of leases removed.
  """
  @decorate with_span("Hyper.Img.Db.Lease.reap_expired")
  def reap_expired do
    query = from(l in __MODULE__, where: l.expires_at < ^DateTime.utc_now())
    {count, _} = Repo.delete_all(query)
    count
  end
end
