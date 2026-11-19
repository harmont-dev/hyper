defmodule Hyper.Img.CreateDerivedTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Dirs
  alias Hyper.Img
  alias Hyper.Img.Db.{Blob, Image, Repo}
  alias Unit.Information

  defp consumable!(bytes) do
    path =
      Path.join(System.tmp_dir!(), "hyper-derived-#{System.unique_integer([:positive])}.img")

    File.write!(path, bytes)
    path
  end

  defp blob_id(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # Opt-in: needs Postgres and a writable layer store. mix test --include external
  @tag :external
  test "create_derived records parent chain + delta, idempotently" do
    {:ok, base_id} = Img.create(consumable!(:crypto.strong_rand_bytes(4096)), label: "base")
    delta_bytes = :crypto.strong_rand_bytes(2048)

    {:ok, img_id} =
      Img.create_derived(base_id, consumable!(delta_bytes), Information.gib(2), label: "delta")

    assert [%Blob{id: ^base_id, kind: :base}, %Blob{kind: :delta} = delta] =
             Image.resolve_chain(img_id)

    assert File.exists?(Path.join(Dirs.layer_dir(), "layer_#{delta.id}.img"))
    assert Image.device_size(base_id) == {:ok, Information.bytes(4096)}
    assert Image.device_size(img_id) == {:ok, Information.gib(2)}

    # Same bytes over the same parent: the same derived image, no duplicates.
    assert {:ok, ^img_id} =
             Img.create_derived(base_id, consumable!(delta_bytes), Information.gib(2),
               label: "delta"
             )

    # The same delta captured on a bigger volume is another image over the same blob.
    assert {:ok, bigger} =
             Img.create_derived(base_id, consumable!(delta_bytes), Information.gib(4))

    assert bigger != img_id
    assert Image.device_size(bigger) == {:ok, Information.gib(4)}
    assert Enum.map(Image.resolve_chain(bigger), & &1.id) == [base_id, delta.id]

    # An unknown parent is refused, never silently recorded.
    assert {:error, {:unknown_parent_image, _}} =
             Img.create_derived("no-such-image", consumable!(<<1>>), Information.gib(2))
  end

  @tag :external
  test "a derived image smaller than its parent is refused and nothing of it is recorded" do
    {:ok, base_id} = Img.create(consumable!(:crypto.strong_rand_bytes(4096)))

    {:ok, parent} =
      Img.create_derived(
        base_id,
        consumable!(:crypto.strong_rand_bytes(2048)),
        Information.gib(4)
      )

    delta_bytes = :crypto.strong_rand_bytes(2048)
    delta_path = consumable!(delta_bytes)

    assert Img.create_derived(parent, delta_path, Information.gib(2)) ==
             {:error, {:smaller_than_parent, Information.gib(2), Information.gib(4)}}

    refute File.exists?(delta_path)
    assert Repo.get(Blob, blob_id(delta_bytes)) == nil

    assert Repo.get(Image, Img.derived_image_id(parent, blob_id(delta_bytes), Information.gib(2))) ==
             nil
  end

  @tag :external
  test "create_vm refuses an image bigger than the instance disk before placing it" do
    {:ok, base_id} = Img.create(consumable!(:crypto.strong_rand_bytes(4096)))
    size = Information.gib(5)

    {:ok, img_id} =
      Img.create_derived(base_id, consumable!(:crypto.strong_rand_bytes(2048)), size)

    too_small =
      Enum.filter(Hyper.Vm.Instance.types(), fn type ->
        Information.as_bytes(Hyper.Vm.Instance.spec(type).disk) < Information.as_bytes(size)
      end)

    assert too_small != []

    for type <- too_small do
      assert Hyper.create_vm(%Hyper.Vm.Spec{img_id: img_id, type: type}) ==
               {:error, {:image_exceeds_disk, size, type}}
    end
  end
end
