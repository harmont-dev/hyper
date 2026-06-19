defmodule Hyper.Node.FireVMM.ProviderTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.Provider

  test "target_arch/0 returns a supported architecture on this host" do
    assert {:ok, arch} = Provider.target_arch()
    assert arch in ["x86_64", "aarch64"]
  end
end
