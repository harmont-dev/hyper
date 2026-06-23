defmodule Hyper.Img.Db.SqliteBackendTest do
  @moduledoc """
  Proves the image-graph queries that depend on database-specific SQL behave
  correctly on SQLite: the lease upsert, the GC prune (correlated subquery +
  RETURNING), and chain resolution.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias Hyper.Img.Db.{Blob, Image, ImageLayer, Lease}
  alias Hyper.Img.Db.Repo.Sqlite, as: Repo

  setup do
    # `mix test --no-start` skips the :hyper application (which would try to
    # connect to Postgres), but :ecto and :ecto_sql must run so
    # Ecto.Repo.Registry and Ecto.MigratorSupervisor are alive.
    Application.ensure_all_started(:ecto_sql)

    dir = System.tmp_dir!()
    db = Path.join(dir, "hyper_sqlite_test_#{System.unique_integer([:positive])}.db")

    pid =
      start_supervised!(
        {Repo, database: db, journal_mode: :wal, pool_size: 1, busy_timeout: 5_000}
      )

    Ecto.Migrator.run(Repo, Path.join([File.cwd!(), "priv", "repo", "migrations"]), :up,
      all: true,
      log: false
    )

    on_exit(fn ->
      File.rm(db)
      File.rm(db <> "-wal")
      File.rm(db <> "-shm")
    end)

    %{repo: pid, db: db}
  end

  defp now, do: DateTime.utc_now()
  defp ago(seconds), do: DateTime.add(now(), -seconds, :second)

  test "Image.resolve_chain returns blobs ordered by layer position" do
    Repo.insert!(%Blob{id: "base", kind: :base, state: :present, size: 100, inserted_at: now()})
    Repo.insert!(%Blob{id: "delta", kind: :delta, state: :present, size: 50, inserted_at: now()})
    Repo.insert!(%Image{id: "img1", label: "test", inserted_at: now()})
    Repo.insert!(%ImageLayer{image_id: "img1", blob_id: "base", position: 0})
    Repo.insert!(%ImageLayer{image_id: "img1", blob_id: "delta", position: 1})

    chain = Repo.all(Image.resolve_chain("img1"))

    assert Enum.map(chain, & &1.id) == ["base", "delta"]
  end

  test "Lease.bump upserts on the (node_id, vm_id) conflict target" do
    Repo.insert!(%Image{id: "img2", inserted_at: now()})

    {:ok, first} = Lease.bump_with_repo(Repo, "img2", "vm-a", Unit.Time.s(60))
    {:ok, second} = Lease.bump_with_repo(Repo, "img2", "vm-a", Unit.Time.s(120))

    # The second call targets the same (node_id, vm_id) key, so the ON CONFLICT
    # DO UPDATE fires: exactly one row persists and the expiry is further out.
    #
    # Note: ecto_sqlite3 builds the returned struct from the changeset rather than
    # reading back the stored row after a conflict update, so `second.id` carries a
    # freshly-generated UUID instead of the original lease's id.

    # returned struct carries the new TTL (built from the changeset, not read back)
    assert DateTime.compare(second.expires_at, first.expires_at) == :gt

    # exactly one row exists (proves upsert updated-in-place, not inserted)
    assert Repo.aggregate(Lease, :count) == 1

    # re-read the stored row and verify its expiry was actually bumped (proves DB update persisted)
    stored = Repo.one!(Lease)
    assert DateTime.compare(stored.expires_at, first.expires_at) == :gt
  end

  test "GC prune deletes only unreferenced blobs and returns their sizes via RETURNING" do
    cutoff = now()

    # Referenced by an image layer -> must survive.
    Repo.insert!(%Blob{id: "kept", kind: :base, state: :present, size: 100, inserted_at: ago(60)})
    Repo.insert!(%Image{id: "img3", inserted_at: now()})
    Repo.insert!(%ImageLayer{image_id: "img3", blob_id: "kept", position: 0})

    # Unreferenced and older than the cutoff -> must be pruned.
    Repo.insert!(%Blob{
      id: "orphan",
      kind: :delta,
      state: :present,
      size: 42,
      inserted_at: ago(60)
    })

    query =
      from b in Blob,
        as: :b,
        where:
          b.state == :present and b.inserted_at < ^cutoff and
            not exists(from il in ImageLayer, where: il.blob_id == parent_as(:b).id),
        select: b.size

    {count, sizes} = Repo.delete_all(query)

    assert count == 1
    assert sizes == [42]
    assert Repo.get(Blob, "kept")
    refute Repo.get(Blob, "orphan")
  end
end
