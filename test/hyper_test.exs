defmodule HyperTest do
  use ExUnit.Case, async: true

  # These pin the routing contract: an unresolvable target short-circuits to
  # {:error, :not_found} on both entry clauses (and the vm_id binary clause
  # exists at all — the old pid-only exec/3 raised FunctionClauseError on a
  # binary), while a *resolvable* vm_id is dispatched through route/4 into the
  # owning node's Hyper.Node.exec/3. The final hop into a live guest/relay is
  # covered by the Hyper.Node.FireVMM.Agent suite and the live E2E.

  test "exec/3 with an unregistered vm_id returns {:error, :not_found}" do
    # A vm_id shaped like a real one but never registered in the routing table.
    assert Hyper.exec("vaaaaaaaaaaaaaaaa", ["/bin/true"]) == {:error, :not_found}
  end

  test "exec/3 with a pid that is not a VM supervisor returns {:error, :not_found}" do
    # self/0 is a live pid but was never registered under {vm_id, :supervisor},
    # so id/1 resolves to nil and exec/3 refuses rather than misrouting.
    assert Hyper.exec(self(), ["/bin/true"]) == {:error, :not_found}
  end

  test "exec/3 routes a resolvable VM into the owning node's Hyper.Node.exec/3, by vm_id and by pid" do
    # Register a stand-in {vm_id, :supervisor} (this test pid) so both entry
    # forms resolve: the vm_id via whereis/1, the pid via id/1's reverse
    # lookup. No relay socket exists for this vm_id, so the call routes all
    # the way through route/4 -> Hyper.Node.exec -> Agent.exec and returns the
    # agent's connect error. The point is that it is NOT :not_found
    # (resolution succeeded) and NOT :node_unreachable (the erpc dispatched),
    # which distinguishes a real route from the short-circuits above.
    vm_id = Hyper.Vm.Id.generate()
    :ok = Hyper.Cluster.Routing.register_self({vm_id, :supervisor})
    await_route(vm_id)

    for entry <- [vm_id, self()] do
      assert {:error, reason} = Hyper.exec(entry, ["/bin/true"])
      refute reason == :not_found, "#{inspect(entry)} must resolve, got :not_found"
      refute reason == :node_unreachable, "#{inspect(entry)} dispatched locally"
    end
  end

  # Horde materialises a registration into the local replica asynchronously, so
  # poll whereis/1 until the entry is visible before routing against it.
  defp await_route(vm_id, tries \\ 200)
  defp await_route(vm_id, 0), do: flunk("routing entry for #{vm_id} never materialised")

  defp await_route(vm_id, tries) do
    case Hyper.whereis(vm_id) do
      nil ->
        Process.sleep(5)
        await_route(vm_id, tries - 1)

      _node ->
        :ok
    end
  end
end
