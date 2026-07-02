defmodule Hyper.Node.FireVMM.GuestAgentTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.GuestAgent

  test "path/1 is a per-arch absolute path under the install dir" do
    x = GuestAgent.path(:x86_64)
    a = GuestAgent.path(:aarch64)
    assert Path.type(x) == :absolute
    assert x != a
    assert String.contains?(x, "x86_64")
    assert String.contains?(a, "aarch64")
  end
end
