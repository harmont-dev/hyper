defmodule Hyper.Node.FireVMM.Jail.StageTest do
  use ExUnit.Case, async: true
  alias Hyper.Node.FireVMM.Jail.Stage

  test "jail filenames are fixed and rooted" do
    assert Stage.jail_kernel_name() == "vmlinux"
    assert Stage.jail_root_name() == "rootfs"
    assert Stage.jail_path(Stage.jail_root_name()) == "/rootfs"
  end
end
