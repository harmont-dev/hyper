defmodule HyperTest do
  use ExUnit.Case, async: true

  # These pin the routing *resolution* contract: an unresolvable target returns
  # {:error, :not_found} on both entry clauses, and the vm_id (binary) clause
  # exists at all (the old pid-only exec/3 raised FunctionClauseError on a
  # binary). The happy-path erpc route into Hyper.Node.exec/3 and the relay is
  # covered by the Hyper.Node.FireVMM.Agent suite and the live E2E, not here —
  # a positive route needs a registered VM (Horde entry) or a booted guest.

  test "exec/3 with an unregistered vm_id returns {:error, :not_found}" do
    # A vm_id shaped like a real one but never registered in the routing table.
    assert Hyper.exec("vaaaaaaaaaaaaaaaa", ["/bin/true"]) == {:error, :not_found}
  end

  test "exec/3 with a pid that is not a VM supervisor returns {:error, :not_found}" do
    # self/0 is a live pid but was never registered under {vm_id, :supervisor},
    # so id/1 resolves to nil and exec/3 refuses rather than misrouting.
    assert Hyper.exec(self(), ["/bin/true"]) == {:error, :not_found}
  end
end
