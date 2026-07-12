defmodule Hyper.Grpc.Pageable.VmTest do
  @moduledoc """
  Pins the VM-specific pagination contract: the cursor is the `vm_id`, and the
  clamp bounds are 100 (default) / 1000 (max). The generic invariants live in
  `Hyper.Grpc.PagePropertiesTest`; this pins the numbers that suite no longer
  knows.
  """
  use ExUnit.Case, async: true

  alias Hyper.Grpc.Pageable.Vm

  test "cursor is the vm_id, independent of the node" do
    assert Vm.cursor({"vm-abc", :node@a}) == "vm-abc"
    assert Vm.cursor({"vm-abc", :node@b}) == "vm-abc"
  end

  test "clamp bounds are 100 default / 1000 max" do
    assert Vm.default_page_size() == 100
    assert Vm.max_page_size() == 1000
  end
end
