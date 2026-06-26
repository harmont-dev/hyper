defmodule Hyper.Cfg.TimeoutsTest do
  use ExUnit.Case, async: true

  alias Hyper.Cfg.Timeouts

  test "idle grace defaults to 30s for every teardown scope" do
    assert Timeouts.idle_ms(:img) == :timer.seconds(30)
    assert Timeouts.idle_ms(:layer) == :timer.seconds(30)
    assert Timeouts.idle_ms(:mutable) == :timer.seconds(30)
  end

  test "firecracker API call timeout default" do
    assert Timeouts.fire_call_ms() == 35_000
  end
end
