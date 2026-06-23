defmodule Hyper.Img.Db.SingleNodeGuardTest do
  use ExUnit.Case, async: true

  alias Hyper.Img.Db.SingleNodeGuard

  test "arms when no peers are connected" do
    assert {:ok, _state} = SingleNodeGuard.init(fn -> [] end)
  end

  test "refuses to start when peers are already connected" do
    peers = [:"b@127.0.0.1", :"c@127.0.0.1"]
    assert {:stop, {:multi_node_sqlite, ^peers}} = SingleNodeGuard.init(fn -> peers end)
  end
end
