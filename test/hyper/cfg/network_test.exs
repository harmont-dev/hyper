defmodule Hyper.Cfg.NetworkTest do
  use ExUnit.Case, async: false
  alias Hyper.Cfg.Network
  alias Hyper.Cfg.Toml

  describe "clone_pool/0" do
    test "defaults when unset" do
      # Mirrors default_clone_pool() in native/suidhelper/src/config.rs — the
      # two literals are safety-critical and must move together.
      assert Network.clone_pool() == "172.31.0.0/16"
    end
  end

  describe "configured?/0" do
    test "false when no uplink configured" do
      # Base test config sets no [network] table. This is the predicate the
      # startup preflight uses to refuse booting a node without networking.
      refute Network.configured?()
    end
  end

  describe "uplink/0" do
    test "raises Hyper.Cfg.MissingError when network.uplink is unset" do
      # Pins the refusal contract: a [network] table present without `uplink`
      # must raise, not silently disable networking or crash uninformatively.
      on_exit(fn -> Toml.reload() end)
      Toml.put_cache(%{"network" => %{}})

      assert_raise Hyper.Cfg.MissingError, ~r/network\.uplink/, fn ->
        Network.uplink()
      end
    end
  end
end
