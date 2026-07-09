defmodule Hyper.Img.Db.LeaseTest do
  @moduledoc """
  Contract of the lease lifecycle against the real image DB:

    * `bump/3` is take-and-heartbeat in one call: first call inserts, a
      repeat for the same (node, vm) moves `expires_at` forward on the SAME
      row — upsert, never a duplicate;
    * `release/1` deletes only the calling node's lease for that vm, and is
      idempotent;
    * `reap_expired/0` removes lapsed leases and leaves live ones;
    * a lease can never reference an unknown image (FK refusal, nothing
      inserted).

  Hits Postgres: excluded from the default run; CI runs it in the
  integration job (`mix test --include external`).
  """
  use ExUnit.Case, async: false

  @moduletag :external

  import Ecto.Query

  alias Hyper.Img.Db.{Lease, Repo}

  setup_all do
    path = Path.join(System.tmp_dir!(), "hyper-lease-#{System.unique_integer([:positive])}.img")
    File.write!(path, :crypto.strong_rand_bytes(1024))
    {:ok, img_id} = Hyper.Img.create(path, label: "lease-test")
    %{img_id: img_id}
  end

  defp lease_rows(vm_id) do
    Repo.all(from l in Lease, where: l.vm_id == ^vm_id and l.node_id == ^to_string(node()))
  end

  defp expire!(vm_id) do
    past = DateTime.add(DateTime.utc_now(), -3600, :second)

    {1, _} =
      Repo.update_all(
        from(l in Lease, where: l.vm_id == ^vm_id and l.node_id == ^to_string(node())),
        set: [expires_at: past]
      )
  end

  test "bump inserts once, then heartbeats: same row, expiry moved forward", %{img_id: img} do
    vm_id = Hyper.Vm.Id.generate()
    on_exit(fn -> Lease.release(vm_id) end)

    assert {:ok, first} = Lease.bump(img, vm_id, Unit.Time.s(60))
    assert {:ok, _} = Lease.bump(img, vm_id, Unit.Time.s(120))

    assert [row] = lease_rows(vm_id)
    assert row.id == first.id
    assert DateTime.compare(row.expires_at, first.expires_at) == :gt
  end

  test "release deletes only the caller's (node, vm) lease, idempotently", %{img_id: img} do
    vm_a = Hyper.Vm.Id.generate()
    vm_b = Hyper.Vm.Id.generate()
    on_exit(fn -> Lease.release(vm_b) end)
    {:ok, _} = Lease.bump(img, vm_a, Unit.Time.s(60))
    {:ok, _} = Lease.bump(img, vm_b, Unit.Time.s(60))

    assert :ok = Lease.release(vm_a)
    assert lease_rows(vm_a) == []
    assert [_survivor] = lease_rows(vm_b)

    assert :ok = Lease.release(vm_a)
  end

  test "reap_expired removes lapsed leases and leaves live ones", %{img_id: img} do
    live = Hyper.Vm.Id.generate()
    lapsed = Hyper.Vm.Id.generate()
    on_exit(fn -> Lease.release(live) end)
    {:ok, _} = Lease.bump(img, live, Unit.Time.s(300))
    {:ok, _} = Lease.bump(img, lapsed, Unit.Time.s(300))
    expire!(lapsed)

    assert Lease.reap_expired() >= 1
    assert lease_rows(lapsed) == []
    assert [_] = lease_rows(live)
  end

  test "a lease on an unknown image is refused by the FK, nothing inserted" do
    vm_id = Hyper.Vm.Id.generate()

    assert {:error, changeset} = Lease.bump(String.duplicate("f", 64), vm_id, Unit.Time.s(60))
    assert {"does not exist", _} = changeset.errors[:image_id]
    assert lease_rows(vm_id) == []
  end
end
