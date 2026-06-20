defmodule Hyper.Img.Db.Repo.Migrations.CreateImageDb do
  use Ecto.Migration

  def change do
    create table(:blobs, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :state, :string, null: false, default: "present"
      add :size, :bigint, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:images, primary_key: false) do
      add :id, :string, primary_key: true
      add :label, :string

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create table(:image_layers, primary_key: false) do
      add :position, :integer, null: false

      add :image_id,
          references(:images, column: :id, type: :string, on_delete: :delete_all),
          null: false

      add :blob_id,
          references(:blobs, column: :id, type: :string, on_delete: :restrict),
          null: false
    end

    # Enforces ordered, gap-checked chains and serves as the composite identity for
    # an image_layers row (no surrogate PK).
    create unique_index(:image_layers, [:image_id, :position])
    # Reverse index: "which images reference this blob" for the delete check.
    create index(:image_layers, [:blob_id])

    create table(:leases, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_id, :string, null: false
      add :vm_id, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :image_id,
          references(:images, column: :id, type: :string, on_delete: :delete_all),
          null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create unique_index(:leases, [:node_id, :vm_id])
    create index(:leases, [:image_id])
    create index(:leases, [:expires_at])
  end
end
