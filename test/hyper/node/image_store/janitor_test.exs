defmodule Hyper.Node.ImageStore.JanitorTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.ImageStore.Janitor

  test "exposes the sweep API" do
    assert function_exported?(Janitor, :start_link, 1)
    assert function_exported?(Janitor, :sweep, 0)
  end

  test "init starts with empty state" do
    assert Janitor.init([]) == {:ok, %{}}
  end

  test "sweep is not implemented yet" do
    assert_raise RuntimeError, "not implemented", fn -> Janitor.sweep() end
  end
end
