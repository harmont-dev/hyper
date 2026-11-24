defmodule Hyper.Img.DeleteTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  alias Hyper.Cfg.Dirs
  alias Hyper.Img
  alias Hyper.Img.Db.{Blob, Image, Lease, Repo}
  alias Unit.Information

  defp consumable!(bytes) do
    path = Path.join(System.tmp_dir!(), "hyper-delete-#{System.unique_integer([:positive])}.img")
    File.write!(path, bytes)
    path
  end

  defp stored?(blob_id) do
    {Repo.get(Blob, blob_id) != nil,
     File.exists?(Path.join(Dirs.layer_dir(), "layer_#{blob_id}.img"))}
  end

  defp vm_id, do: "vm-#{System.unique_integer([:positive])}"

  # Opt-in: needs Postgres and a writable layer store. mix test --include external
  @tag :external
  test "delete drops the image and the blobs only it uses, and keeps what a derived image shares" do
    {:ok, base} = Img.create(consumable!(:crypto.strong_rand_bytes(4096)))

    {:ok, derived} =
      Img.create_derived(base, consumable!(:crypto.strong_rand_bytes(2048)), Information.gib(2))

    [_base_blob, %Blob{id: delta}] = Image.resolve_chain(derived)

    assert Img.delete(base) == :ok
    assert Repo.get(Image, base) == nil
    assert stored?(base) == {true, true}
    assert Enum.map(Image.resolve_chain(derived), & &1.id) == [base, delta]

    assert Img.delete(derived) == :ok
    assert Repo.get(Image, derived) == nil
    assert stored?(base) == {false, false}
    assert stored?(delta) == {false, false}
  end

  @tag :external
  test "delete refuses while a VM holds a live lease, and goes through once the lease lapses" do
    {:ok, img} = Img.create(consumable!(:crypto.strong_rand_bytes(4096)))
    vm = vm_id()
    {:ok, _lease} = Lease.bump(img, vm, Lease.default_ttl())

    assert Img.delete(img) == {:error, :in_use}
    assert stored?(img) == {true, true}

    lapsed = DateTime.add(DateTime.utc_now(), -1, :second)
    {1, _} = Repo.update_all(from(l in Lease, where: l.vm_id == ^vm), set: [expires_at: lapsed])

    assert Img.delete(img) == :ok
    assert stored?(img) == {false, false}
  end

  @tag :external
  test "an image that is gone is :unknown_image and can no longer be leased" do
    {:ok, img} = Img.create(consumable!(:crypto.strong_rand_bytes(4096)))
    assert Img.delete(img) == :ok

    for id <- [img, "no-such-image"] do
      assert Img.delete(id) == {:error, :unknown_image}
      assert {:error, %Ecto.Changeset{}} = Lease.bump(id, vm_id(), Lease.default_ttl())
    end
  end

  @tag :external
  test "the same bytes can be created again after their image was deleted" do
    bytes = :crypto.strong_rand_bytes(4096)
    {:ok, img} = Img.create(consumable!(bytes))
    assert Img.delete(img) == :ok

    assert Img.create(consumable!(bytes)) == {:ok, img}
    assert stored?(img) == {true, true}
    assert [%Blob{id: ^img}] = Image.resolve_chain(img)
  end
end
