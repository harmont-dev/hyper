defmodule Hyper.Node.Img.ThinPoolTest do
  use ExUnit.Case, async: true
  alias Hyper.Node.Img.ThinPool

  test "id_alloc bumps then reuses freed ids LIFO" do
    s0 = %{next: 0, freed: []}
    {0, s1} = ThinPool.id_alloc(s0)
    {1, s2} = ThinPool.id_alloc(s1)
    s3 = ThinPool.id_free(s2, 0)
    assert {0, _} = ThinPool.id_alloc(s3)
  end
end
