defmodule Hyper.Img.CreateDerivedTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Dirs
  alias Hyper.Img
  alias Hyper.Img.Db.{Blob, Image}

  defp consumable!(bytes) do
    path =
      Path.join(System.tmp_dir!(), "hyper-derived-#{System.unique_integer([:positive])}.img")

    File.write!(path, bytes)
    path
  end

  # Opt-in: needs Postgres and a writable layer store. mix test --include external
  @tag :external
  test "create_derived records parent chain + delta, idempotently" do
    {:ok, base_id} = Img.create(consumable!(:crypto.strong_rand_bytes(4096)), label: "base")
    delta_bytes = :crypto.strong_rand_bytes(2048)

    {:ok, img_id} = Img.create_derived(base_id, consumable!(delta_bytes), label: "delta")

    assert [%Blob{id: ^base_id, kind: :base}, %Blob{kind: :delta} = delta] =
             Image.resolve_chain(img_id)

    assert File.exists?(Path.join(Dirs.layer_dir(), "layer_#{delta.id}.img"))

    # Same bytes over the same parent: the same derived image, no duplicates.
    assert {:ok, ^img_id} = Img.create_derived(base_id, consumable!(delta_bytes), label: "delta")

    # An unknown parent is refused, never silently recorded.
    assert {:error, {:unknown_parent_image, _}} =
             Img.create_derived("no-such-image", consumable!(<<1>>))
  end
end
