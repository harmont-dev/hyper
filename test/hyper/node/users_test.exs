defmodule Hyper.Node.UsersTest do
  use ExUnit.Case, async: false
  alias Hyper.Node.Users

  setup do
    start_supervised!(Users)
    :ok
  end

  test "bind frees the id when the owner dies" do
    {:ok, id} = Users.claim()
    owner = spawn(fn -> Process.sleep(:infinity) end)
    :ok = Users.bind(id, owner)
    Process.exit(owner, :kill)
    # The freed id is reused on the next claim.
    Process.sleep(20)
    assert {:ok, ^id} = Users.claim()
  end
end
