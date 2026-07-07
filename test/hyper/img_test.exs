defmodule Hyper.ImgTest do
  @moduledoc """
  Laws of the pure derived-image helpers:

    * `derived_image_id/2` is a deterministic 64-char lowercase-hex digest, and
      distinct (parent, delta) inputs yield distinct ids (injective on samples);
    * `derived_layer_rows/3` preserves the parent chain order as a prefix,
      appends the delta last, and numbers positions contiguously from 0 —
      exactly the shape `Db.Image.resolve_chain/1` reassembles.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Img

  defp id_gen, do: string([?a..?f, ?0..?9], min_length: 4, max_length: 64)

  property "derived_image_id is deterministic lowercase hex of length 64" do
    check all(parent <- id_gen(), delta <- id_gen()) do
      id = Img.derived_image_id(parent, delta)

      assert id == Img.derived_image_id(parent, delta)
      assert String.match?(id, ~r/^[0-9a-f]{64}$/)
    end
  end

  property "distinct inputs give distinct derived ids" do
    check all(a <- id_gen(), b <- id_gen(), delta <- id_gen(), a != b) do
      assert Img.derived_image_id(a, delta) != Img.derived_image_id(b, delta)
      assert Img.derived_image_id(a, delta) != Img.derived_image_id(a, "#{delta}0")
    end
  end

  property "derived_layer_rows keeps parent order, appends delta, numbers 0..n" do
    check all(parents <- list_of(id_gen(), max_length: 8), delta <- id_gen()) do
      img_id = Img.derived_image_id("p", delta)
      rows = Img.derived_layer_rows(img_id, parents, delta)

      assert Enum.map(rows, & &1.blob_id) == parents ++ [delta]
      assert Enum.map(rows, & &1.position) == Enum.to_list(0..length(parents))
      assert Enum.all?(rows, &(&1.image_id == img_id))
    end
  end
end
