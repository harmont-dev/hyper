defmodule HyperTest do
  use ExUnit.Case, async: true

  setup do
    # Under `mix test --no-start` (CI: the supervision tree provisions a real
    # Firecracker host, unavailable there) the app's Routing registry is
    # absent; start a test-scoped one so the resolution contract is testable
    # without the full tree. On a dev box with the app running this is a no-op.
    unless Process.whereis(Hyper.Cluster.Routing) do
      _ = Application.ensure_all_started(:horde)
      # The routed test ends in Agent.exec's gRPC connect; without the :grpc
      # app its client supervisor is down and the connect crashes (:noproc)
      # instead of returning the {:error, _} the contract expects.
      _ = Application.ensure_all_started(:grpc)
      start_supervised!(Hyper.Cluster.Routing)
    end

    :ok
  end

  # These pin the routing contract: an unresolvable target short-circuits to
  # {:error, :not_found} on both entry clauses (and the vm_id binary clause
  # exists at all — the old pid-only exec/3 raised FunctionClauseError on a
  # binary), while a *resolvable* vm_id is dispatched through route/4 into the
  # owning node's Hyper.Node.exec/3. The final hop into a live guest/relay is
  # covered by the Hyper.Node.FireVMM.Agent suite and the live E2E.

  # Every cluster entry point that resolves a VM to a node must short-circuit to
  # {:error, :not_found} when the target is unresolvable, rather than misroute or
  # crash. `:__self__` resolves to this test's pid at runtime: a live pid that was
  # never registered as a {vm_id, :supervisor}, so id/1 reverse-resolves to nil.
  for {name, {fun, args}} <- [
        {"exec/3 by an unregistered vm_id", {:exec, ["vaaaaaaaaaaaaaaaa", ["/bin/true"]]}},
        {"exec/3 by a non-supervisor pid", {:exec, [:__self__, ["/bin/true"]]}},
        {"usage/1 by a non-supervisor pid", {:usage, [:__self__]}},
        {"fork_vm/1 by an unregistered vm_id", {:fork_vm, ["vaaaaaaaaaaaaaaaa"]}}
      ] do
    test "#{name} refuses with {:error, :not_found}" do
      {fun, args} = unquote(Macro.escape({fun, args}))

      args =
        Enum.map(args, fn
          :__self__ -> self()
          other -> other
        end)

      assert apply(Hyper, fun, args) == {:error, :not_found}
    end
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

  test "id/1 answers nil when the VM's owning node is unreachable" do
    # id/1 erpc's to node(pid). When that node can never be reached, the {:erpc,
    # :noconnection} transport failure must degrade to nil (the VM died with its
    # host, so "unknown" is truthful) rather than crash the caller.
    unreachable = fabricate_pid_on(:"ghost@127.0.0.1")
    assert Hyper.id(unreachable) == nil
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

  # A pid term whose node/1 is `node_name`, built without connecting to it. The
  # external NEW_PID_EXT (tag 88) form: node as a SMALL_ATOM_UTF8_EXT (tag 119,
  # 8-bit length), then id/serial/creation words. Lets us exercise the
  # unreachable-owning-node path with no peer node, epmd, or distribution.
  defp fabricate_pid_on(node_name) do
    node_bin = :erlang.atom_to_binary(node_name, :utf8)

    :erlang.binary_to_term(
      <<131, 88, 119, byte_size(node_bin)::8, node_bin::binary, 1::32, 0::32, 1::32>>
    )
  end
end
