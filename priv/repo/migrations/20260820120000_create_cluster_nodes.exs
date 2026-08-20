defmodule Hyper.Img.Db.Repo.Migrations.CreateClusterNodes do
  use Ecto.Migration

  def change do
    create table(:cluster_nodes, primary_key: false) do
      add :node, :string, primary_key: true
      add :role, :string, null: false
      add :updated_at, :utc_datetime_usec, null: false
    end

    create index(:cluster_nodes, [:updated_at])
  end
end
