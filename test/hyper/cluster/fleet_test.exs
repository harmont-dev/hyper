defmodule Hyper.Cluster.FleetTest do
  @moduledoc """
  The classification `Hyper.Cluster.Fleet.machines/0` reports, and the facade's
  refusal to pass a broken provider off as a small fleet.

  Laws under test for the join — the cross of what the provider lists with the
  nodes that are actually in the cluster:

    * **Total, and exactly once.** Every listed machine and every cluster member
      is classified, none of them twice: the provider's records come back
      one-for-one in the order it listed them, and the orphans are exactly the
      members no record claims.
    * **`:joined` iff a member.** A listed machine is `:joined` exactly when it
      names a node that is in the cluster. Everything else it can be is
      `:pending`, including a machine the provider cannot name a node for yet.
    * **`:orphan` is the set difference**, so an empty listing makes every
      cluster member an orphan and a listing that covers them all produces none.
    * **Shape follows membership.** An orphan carries a node and no provider
      record; every other entry carries a record, its own node, and the Fleet id
      — the claim, not the provider's id — that `cordon/1`, `drain/1` and
      `uncordon/1` accept.

  The refusal contract on top: a provider that cannot be built or cannot be
  listed is an error, never an empty fleet, because an empty fleet reads as "every
  node is an orphan" and Fleet must never mutate on that reading. The same applies
  to the levers: an id no controller holds is `{:error, :not_found}`, never an
  exit in the operator's shell.

  `machines/0` against a live `Hyper.Cluster.Budget` is deliberately not tested
  here: the joined half of the cross is whatever the cluster this suite runs in
  happens to contain, which is a property of the environment, not of this module.
  It is covered where a real cluster exists.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Cluster.Fleet
  alias Hyper.Cluster.Fleet.Machine
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Fleet.Provider.Static
  alias Hyper.Cluster.Routing

  defmodule FailingProvider do
    @moduledoc false
    @behaviour Hyper.Cluster.Fleet.Provider

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def capabilities(_state), do: []

    @impl true
    def list(_state), do: {:error, :listing_unavailable}

    @impl true
    def create(_state, _tags), do: {:error, :not_supported}

    @impl true
    def destroy(_state, _id), do: :ok
  end

  @unusable [
    {"a provider that cannot be built", [provider: Static, provider_opts: [nodes: :everything]],
     {:bad_nodes, :everything}},
    {"a provider that cannot be listed", [provider: FailingProvider], :listing_unavailable}
  ]

  test "a fleet is the machines that joined, the ones that have not, and the nodes nothing accounts for" do
    joined = %Info{id: "m-1", node: :hyper@a, status: :active}
    booting = %Info{id: "m-2", node: :hyper@b, status: :pending}
    unnamed = %Info{id: "m-3", node: nil, status: :pending}

    assert [
             %{id: "m-1", node: :hyper@a, membership: :joined},
             %{id: "m-2", node: :hyper@b, membership: :pending},
             %{id: "m-3", node: nil, membership: :pending},
             %{id: nil, node: :hyper@c, membership: :orphan}
           ] = Fleet.join([joined, booting, unnamed], [:hyper@a, :hyper@c])
  end

  test "a machine created by a controller is keyed by its claim, not by the provider's id" do
    created = %Info{
      id: "vultr-8891",
      node: :hyper@a,
      status: :active,
      tags: %{Machine.claim_tag() => "claim-1"}
    }

    assert [%{id: "claim-1"}] = Fleet.join([created], [:hyper@a])
  end

  property "a listed machine survives in order, and is :joined exactly when its node is a member" do
    check all({listed, members} <- fleet()) do
      entries = Fleet.join(listed, members)
      kept = Enum.reject(entries, &(&1.membership == :orphan))
      member_set = MapSet.new(members)

      assert Enum.map(kept, & &1.info) == listed

      for entry <- kept do
        expected = if entry.node in member_set, do: :joined, else: :pending
        assert entry.membership == expected
      end
    end
  end

  property "every listed machine and every cluster member is classified exactly once" do
    check all({listed, members} <- fleet()) do
      entries = Fleet.join(listed, members)
      claimed = for %Info{node: node} <- listed, not is_nil(node), into: MapSet.new(), do: node
      orphans = MapSet.difference(MapSet.new(members), claimed)

      assert length(entries) == length(listed) + MapSet.size(orphans)

      named = for %{node: node} <- entries, not is_nil(node), into: MapSet.new(), do: node
      assert named == MapSet.union(claimed, MapSet.new(members))

      for member <- members do
        assert Enum.count(entries, &(&1.node == member)) == 1
      end
    end
  end

  property "an entry's shape follows its membership" do
    check all({listed, members} <- fleet()) do
      for entry <- Fleet.join(listed, members), do: assert_shape(entry)
    end
  end

  describe "resolving the configured provider" do
    setup do
      Application.delete_env(:hyper, Hyper.Cfg.Fleet)

      on_exit(fn ->
        Application.delete_env(:hyper, Hyper.Cfg.Fleet)
        :persistent_term.erase(Hyper.Cfg.Fleet)
      end)
    end

    for {label, env, reason} <- @unusable do
      test "machines/0 surfaces #{label} rather than an empty fleet" do
        Application.put_env(:hyper, Hyper.Cfg.Fleet, unquote(Macro.escape(env)))

        assert Fleet.machines() == {:error, unquote(Macro.escape(reason))}
      end
    end

    test "grow/1 refuses on a provider that does not implement create" do
      Application.put_env(:hyper, Hyper.Cfg.Fleet, provider: Static, provider_opts: [])

      assert Fleet.grow() == {:error, :not_supported}
    end
  end

  describe "the levers" do
    setup do
      unless Process.whereis(Routing.name()) do
        start_supervised!(Routing)
      end

      :ok
    end

    for lever <- [:cordon, :drain, :uncordon] do
      test "#{lever}/1 answers :not_found for an id no controller holds" do
        assert apply(Fleet, unquote(lever), ["no-such-machine"]) == {:error, :not_found}
      end
    end
  end

  defp assert_shape(%{membership: :orphan} = entry) do
    assert entry.info == nil
    assert entry.id == nil
    assert entry.node != nil
  end

  defp assert_shape(entry) do
    assert %Info{} = entry.info
    assert entry.id == Machine.key(entry.info)
    assert entry.node == entry.info.node
  end

  # A fleet drawn as three disjoint groups over one pool of node names — machines
  # that are in the cluster, machines that are not, and cluster members no machine
  # accounts for — plus machines the provider cannot yet name a node for.
  defp fleet do
    gen all(
          nodes <- uniq_list_of(node_name(), max_length: 8),
          roles <- fixed_list(Enum.map(nodes, fn _node -> role() end)),
          nameless <- integer(0..3)
        ) do
      tagged = Enum.zip(nodes, roles)

      listed =
        for({node, role} <- tagged, role in [:both, :listed], do: info(node)) ++
          for(nth <- 1..nameless//1, do: unnamed(nth))

      {listed, for({node, role} <- tagged, role in [:both, :member], do: node)}
    end
  end

  defp role, do: member_of([:both, :listed, :member])

  defp node_name, do: map(integer(1..32), &:"hyper@10.0.0.#{&1}")

  defp info(node), do: %Info{id: "m-" <> Atom.to_string(node), node: node, status: :active}

  defp unnamed(nth), do: %Info{id: "pending-#{nth}", node: nil, status: :pending}
end
