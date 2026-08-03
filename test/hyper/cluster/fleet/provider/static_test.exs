defmodule Hyper.Cluster.Fleet.Provider.StaticTest do
  @moduledoc """
  Laws of the default provider, a fleet that is declared rather than discovered:

    * **Faithful listing** — `list/1` reports exactly the configured machines, in
      the configured order, each keyed by its node name, marked `:active` and
      carrying the configured tags. It never invents or drops a machine.
    * **Notation is not meaning** — a fleet declared with string node names is
      the same fleet as one declared with atoms.
    * **Refusal** — `create/2` refuses every request, for every input, in
      agreement with `capabilities/1` declaring neither mutation. `destroy/2`
      answers `:ok` for any id in the same breath, because nothing was asked of
      a vendor and so nothing failed.
    * **Refusal on bad declarations** — a malformed `nodes:`/`tags:` option fails
      `init/1` with an error naming the offending value, and is never silently
      coerced into a fleet.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Cluster.Fleet.Provider
  alias Hyper.Cluster.Fleet.Provider.Static

  # A pool rather than generated atoms: node names are operator-written, and
  # generating them would grow the atom table for no extra coverage.
  @pool [
    :"hyper@10.0.0.1",
    :"hyper@10.0.0.2",
    :"hyper@10.0.0.3",
    :"hyper@10.0.0.4",
    :"hyper@10.0.0.5",
    :"hyper@10.0.0.6"
  ]

  property "list/1 reports exactly the configured fleet, in order, tagged and keyed by node name" do
    check all(nodes <- fleet(), tags <- tags()) do
      assert {:ok, state} = Static.init(nodes: nodes, tags: tags)
      assert {:ok, machines} = Static.list(state)

      assert Enum.map(machines, & &1.node) == nodes
      assert Enum.map(machines, & &1.id) == Enum.map(nodes, &Atom.to_string/1)
      assert Enum.all?(machines, &(&1.status == :active))
      assert Enum.all?(machines, &(&1.tags == tags))
    end
  end

  property "a fleet declared with string node names is the same fleet as one declared with atoms" do
    check all(nodes <- fleet()) do
      assert {:ok, from_atoms} = Static.init(nodes: nodes)
      assert {:ok, from_strings} = Static.init(nodes: Enum.map(nodes, &Atom.to_string/1))

      assert Static.list(from_atoms) == Static.list(from_strings)
    end
  end

  property "create/2 refuses every request, and the provider declares no capability to do it" do
    check all(nodes <- fleet(), tags <- tags(), id <- machine_id()) do
      assert {:ok, state} = Static.init(nodes: nodes)

      assert Static.create(state, tags) == {:error, :not_supported}
      assert Static.capabilities(state) == []
      refute Provider.supports?(Static, state, :create)

      # Declaring no `:destroy` and answering `:ok` to one is not a
      # contradiction: nothing was asked of the vendor, so nothing failed.
      assert Static.destroy(state, id) == :ok
      refute Provider.supports?(Static, state, :destroy)
    end
  end

  test "an unconfigured provider is an empty fleet, not an error" do
    assert {:ok, state} = Static.init([])
    assert Static.list(state) == {:ok, []}
  end

  # Refusal contracts: a declaration that cannot be honoured must fail `init/1`
  # naming the offending value. Table-driven — one assertion shape, rows differ
  # only in the bad option and the expected error.
  @bad_opts [
    {[nodes: :"hyper@10.0.0.1"], {:error, {:bad_nodes, :"hyper@10.0.0.1"}}},
    {[nodes: %{}], {:error, {:bad_nodes, %{}}}},
    {[nodes: [:"hyper@10.0.0.1", 42]], {:error, {:bad_node, 42}}},
    {[nodes: [nil]], {:error, {:bad_node, nil}}},
    {[tags: "role=hyper"], {:error, {:bad_tags, "role=hyper"}}},
    {[tags: %{"role" => :hyper}], {:error, {:bad_tags, %{"role" => :hyper}}}},
    {[tags: %{role: "hyper"}], {:error, {:bad_tags, %{role: "hyper"}}}}
  ]

  for {opts, expected} <- @bad_opts do
    @opts opts
    @expected expected
    test "init/1 rejects #{inspect(@opts)} with #{inspect(@expected)}" do
      assert Static.init(@opts) == @expected
    end
  end

  defp fleet, do: uniq_list_of(member_of(@pool), max_length: 4)

  # Ids of configured machines and ids of machines this provider has never heard
  # of: `destroy/2` owes the same answer to both.
  defp machine_id do
    one_of([map(member_of(@pool), &Atom.to_string/1), string(:alphanumeric)])
  end

  defp tags do
    map_of(string(:alphanumeric, min_length: 1), string(:alphanumeric), max_length: 3)
  end
end
