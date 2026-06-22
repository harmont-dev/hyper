defmodule HyperTest do
  use ExUnit.Case, async: true

  test "gen_vm_id is dm-name-safe" do
    id = Hyper.gen_vm_id()
    assert id =~ ~r/^[A-Za-z0-9._-]+$/
    refute id =~ "/"
  end

  test "create_vm requires img_id" do
    assert_raise FunctionClauseError, fn -> Hyper.create_vm(%{}) end
  end
end
