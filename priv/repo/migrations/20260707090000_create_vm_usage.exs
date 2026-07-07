defmodule Hyper.Img.Db.Repo.Migrations.CreateVmUsage do
  use Ecto.Migration

  def change do
    create table(:vm_usage, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_id, :string, null: false
      add :vm_id, :string, null: false
      add :window_start, :utc_datetime_usec, null: false
      add :window_end, :utc_datetime_usec, null: false
      add :cpu_usec, :bigint, null: false

      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    # Both the billing access path (all windows for a VM, optionally
    # range-bounded by window_start) and the idempotency key for flush
    # retries: window_start does not advance on a failed flush, so a retry
    # carries the same (vm_id, window_start) and is dropped as a conflict
    # instead of double-billed.
    create unique_index(:vm_usage, [:vm_id, :window_start])
  end
end
