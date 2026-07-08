defmodule Hyper.SuidHelper.NetworkTest do
  use ExUnit.Case, async: true
  alias Hyper.SuidHelper.Network

  test "prepare/2 builds the network prepare argv" do
    assert Network.argv(:prepare, "vabc", 900_100) ==
             ["network", "prepare", "--vm-id", "vabc", "--uid", "900100"]
  end

  test "teardown/2 builds the network teardown argv" do
    assert Network.argv(:teardown, "vabc", 900_100) ==
             ["network", "teardown", "--vm-id", "vabc", "--uid", "900100"]
  end
end
