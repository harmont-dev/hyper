defmodule Hyper.Node.BlobSourceTest do
  use ExUnit.Case, async: true

  test "declares the truth-tier callbacks" do
    callbacks = Hyper.Node.BlobSource.behaviour_info(:callbacks)

    assert {:resolve, 1} in callbacks
    assert {:fetch, 2} in callbacks
    assert {:put, 1} in callbacks
  end
end
