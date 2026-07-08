defmodule Hyper.Cfg.NetworkTest do
  use ExUnit.Case, async: true
  alias Hyper.Cfg.Network

  describe "clone_pool/0" do
    test "defaults when unset" do
      assert Network.clone_pool() == "172.31.0.0/16"
    end
  end

  describe "enabled?/0" do
    test "false when no uplink configured" do
      # Base test config sets no [network] table.
      refute Network.enabled?()
    end
  end
end
