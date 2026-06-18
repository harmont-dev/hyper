defmodule Hyper.Node.CowTest do
  use ExUnit.Case, async: true

  test "declares the copy-on-write callbacks" do
    callbacks = Hyper.Node.Cow.behaviour_info(:callbacks)

    assert {:available?, 0} in callbacks
    assert {:clone, 2} in callbacks
    assert {:destroy, 1} in callbacks
  end
end
