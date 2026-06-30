defmodule Hyper.Node.RefcountedRestartTest do
  use ExUnit.Case, async: true

  # These three servers are monitor-refcounted and idle-reap: when their last
  # holder goes away they self-terminate with `{:stop, :normal}`, destroying an
  # external device-mapper resource in `terminate/2`. Under a DynamicSupervisor a
  # `:permanent` child is RESTARTED on that intentional `:normal` exit, and its
  # `init/1` re-creates the resource it just tore down -- an endless resurrection
  # loop that leaks dm devices. They MUST be `:temporary` so idle-teardown is
  # final. This pins that invariant for every server in the refcount tier and for
  # any new one added later.
  @idle_reaping_servers [
    Hyper.Node.Img.Mutable,
    Hyper.Node.Img.Server,
    Hyper.Node.Layer.Server
  ]

  for mod <- @idle_reaping_servers do
    test "#{inspect(mod)} is restart: :temporary so its idle :stop is not undone" do
      assert unquote(mod).child_spec([]).restart == :temporary
    end
  end
end
