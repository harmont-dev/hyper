defmodule Hyper.Img.Db.Gc.PruneTest do
  @moduledoc """
  Safety contracts of the GC delete step against real Postgres and the real
  layer store (the laws are stated in `Prune`'s moduledoc): prune only what
  is missing AND unreferenced AND out of grace AND on a healthy medium; the
  DELETE re-checks references; `presence/1` maps only a true `:enoent` to
  `:missing`. Every test creates uniquely-named rows/files and removes them
  on exit.

  Hits Postgres + the configured layer store: excluded from the default
  run; CI runs it in the integration job (`mix test --include external`).
  """
  use ExUnit.Case, async: false

  @moduletag :external

  import Ecto.Query

  alias Hyper.Cfg
  alias Hyper.Cfg.Toml
  alias Hyper.Img.Db.{Blob, Image, ImageLayer, Repo}
  alias Hyper.Img.Db.Gc.Prune

  defp config(overrides \\ []) do
    struct!(
      %Cfg.Gc{
        batch_size: 100,
        batch_pause: Unit.Time.ms(1),
        sweep_interval: Unit.Time.s(60),
        acquire_interval: Unit.Time.s(5),
        retry: Unit.Time.s(60),
        timeout: Unit.Time.s(5),
        grace_period: Unit.Time.s(0)
      },
      overrides
    )
  end

  defp unique_id, do: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)

  defp insert_blob!(id, opts) do
    age_s = Keyword.get(opts, :age_s, 3600)

    Repo.insert!(%Blob{
      id: id,
      kind: :delta,
      size: Keyword.get(opts, :size, 1000),
      inserted_at: DateTime.add(DateTime.utc_now(), -age_s, :second)
    })
  end

  defp blob!(opts) do
    id = unique_id()
    insert_blob!(id, opts)
    on_exit(fn -> Repo.delete_all(from b in Blob, where: b.id == ^id) end)
    id
  end

  # A blob referenced by an image_layer row (ON DELETE RESTRICT on blob_id).
  defp referenced_blob!(opts) do
    blob_id = unique_id()
    img_id = unique_id()
    insert_blob!(blob_id, opts)
    Repo.insert!(%Image{id: img_id, label: "gc-prune-test"})
    Repo.insert!(%ImageLayer{image_id: img_id, blob_id: blob_id, position: 0})

    on_exit(fn ->
      Repo.delete_all(from il in ImageLayer, where: il.image_id == ^img_id)
      Repo.delete_all(from i in Image, where: i.id == ^img_id)
      Repo.delete_all(from b in Blob, where: b.id == ^blob_id)
    end)

    blob_id
  end

  test "a missing, unreferenced, out-of-grace blob is pruned and its bytes counted" do
    id = blob!(size: 2048, age_s: 3600)

    assert Prune.execute(config(), [{id, 2048}]) == {1, 2048, 0}
    assert Repo.get(Blob, id) == nil
  end

  test "a missing blob still referenced by an image is dangling: reported, never deleted" do
    id = referenced_blob!(size: 512, age_s: 3600)

    assert Prune.execute(config(), [{id, 512}]) == {0, 0, 1}
    assert Repo.get(Blob, id)
  end

  test "rows inside the grace period are never deleted, even when missing and unreferenced" do
    id = blob!(age_s: 0)

    assert Prune.execute(config(grace_period: Unit.Time.s(3600)), [{id, 1000}]) == {0, 0, 0}
    assert Repo.get(Blob, id)
  end

  test "the DELETE re-checks references: a row referenced after the snapshot is skipped" do
    # Simulate the race by handing prune_rows an id that IS referenced: the
    # NOT EXISTS clause, not the caller's earlier snapshot, must protect it.
    id = referenced_blob!(age_s: 3600)
    future_cutoff = DateTime.add(DateTime.utc_now(), 3600, :second)

    assert Prune.prune_rows(config(), [id], future_cutoff) == {0, 0}
    assert Repo.get(Blob, id)
  end

  test "a medium that vanished between probe and delete skips the page's deletions" do
    id = blob!(age_s: 3600)

    # Point the layer store at a nonexistent dir only for the duration of the
    # call: test_system must fail and Prune must refuse every delete. Safe to
    # do globally-briefly: unknown/system-error never deletes, by design.
    result =
      try do
        Toml.put_cache(%{"img" => %{"store" => "/nonexistent-hyper-gc-prune-test"}})
        Prune.execute(config(), [{id, 1000}])
      after
        Toml.reload()
      end

    assert result == {0, 0, 0}
    assert Repo.get(Blob, id)
  end

  test "presence/1: real file :present, true absence :missing, any other errno :unknown" do
    store = Hyper.Cfg.Dirs.layer_dir()
    id = unique_id()
    file = Path.join(store, "layer_#{id}.img")
    File.write!(file, "x")
    on_exit(fn -> File.rm(file) end)

    assert Prune.presence(id) == :present
    assert Prune.presence(unique_id()) == :missing

    # Probe a path that traverses THROUGH the regular file: stat fails with
    # :enotdir — not :enoent — and must classify :unknown (never prunable),
    # standing in for ESTALE/EIO on a wobbling NFS mount.
    assert Prune.presence("#{id}.img/nested") == :unknown
  end
end
