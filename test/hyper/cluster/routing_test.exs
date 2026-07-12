defmodule Hyper.Cluster.RoutingTest do
  @moduledoc """
  Routing registry contracts beyond the resolution paths covered by `HyperTest`:

    * `register_self/1` is idempotent-by-error: registering a key that is
      already held returns `{:error, {:already_registered, _}}` rather than
      crashing or silently replacing the owner.
    * `all/0` reports every registered VM supervisor paired with the node
      its process lives on (the cluster-wide inventory callers rely on).
  """

  use ExUnit.Case, async: false

  alias Hyper.Cluster.Routing

  setup do
    # Under `mix test --no-start` the app tree (which provisions Routing) is
    # absent; start a test-scoped registry so these contracts are testable
    # without the full supervision tree. Routing is a named singleton, so if
    # another test (e.g. HyperTest) already started it, reuse that one rather
    # than racing on start_supervised!/1.
    if Process.whereis(Routing) do
      :ok
    else
      _ = Application.ensure_all_started(:horde)

      case start_supervised(Routing) do
        {:ok, _pid} -> :ok
        # Lost the start race to a parallel test: reuse the existing registry.
        {:error, {:already_started, _pid}} -> :ok
      end
    end
  end

  # Horde materialises a registration into the local replica asynchronously, so
  # poll until the entry is visible before asserting against it.
  defp await_materialised?(key, tries \\ 200)
  defp await_materialised?(_key, 0), do: false

  defp await_materialised?(key, tries) do
    if Horde.Registry.lookup(Routing, key) != [],
      do: true,
      else: await_materialised?(key, tries - 1)
  end

  test "register_self/1 returns {:error, {:already_registered, _}} for a held key" do
    key = {Hyper.Vm.Id.generate(), :supervisor}
    assert :ok = Routing.register_self(key)
    assert await_materialised?(key)

    # The same process registering the same key again must report the conflict,
    # not replace the owner or crash -- callers branch on this tuple.
    assert {:error, {:already_registered, pid}} = Routing.register_self(key)
    assert pid == self()
  end

  test "all/0 lists every registered supervisor as {vm_id, node}" do
    vm_id = Hyper.Vm.Id.generate()
    :ok = Routing.register_self({vm_id, :supervisor})
    assert await_materialised?({vm_id, :supervisor})

    assert {^vm_id, node} = List.keyfind(Routing.all(), vm_id, 0)
    assert node == node()
  end
end
