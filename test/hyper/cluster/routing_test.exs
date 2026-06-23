defmodule Hyper.Cluster.RoutingTest do
  use ExUnit.Case, async: false

  alias Hyper.Cluster.Routing

  setup do
    # --no-start means the app (and this registry) is not running; start it here.
    start_supervised!(Routing)
    :ok
  end

  defp register(key) do
    # Register the current test pid under a routing key, the way a VM
    # supervisor registers itself via Hyper.Cluster.Routing.via/1.
    {:ok, _} = Horde.Registry.register(Routing.name(), key, nil)
    self()
  end

  test "id_for/1 returns the vm_id whose :supervisor entry is the pid" do
    pid = register({"vm-abc", :supervisor})
    assert Routing.id_for(pid) == "vm-abc"
  end

  test "id_for/1 returns nil for an unregistered pid" do
    assert Routing.id_for(self()) == nil
  end

  test "all/0 lists every vm_id with its node" do
    register({"vm-1", :supervisor})
    register({"vm-2", :supervisor})
    # A non-supervisor entry must NOT show up.
    register({"vm-1", :client})

    assert Enum.sort(Routing.all()) == [{"vm-1", node()}, {"vm-2", node()}]
  end
end
