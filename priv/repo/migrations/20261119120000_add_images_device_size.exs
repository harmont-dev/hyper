defmodule Hyper.Img.Db.Repo.Migrations.AddImagesDeviceSize do
  use Ecto.Migration

  def up do
    alter table(:images) do
      add :device_size, :bigint
    end

    execute("""
    UPDATE images SET device_size = blobs.size
    FROM image_layers, blobs
    WHERE image_layers.image_id = images.id
      AND image_layers.position = 0
      AND blobs.id = image_layers.blob_id
    """)

    alter table(:images) do
      modify :device_size, :bigint, null: false
    end
  end

  def down do
    alter table(:images) do
      remove :device_size
    end
  end
end
