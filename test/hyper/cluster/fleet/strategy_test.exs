defmodule Hyper.Cluster.Fleet.StrategyTest do
  @moduledoc """
  What the strategy promises distribution, driven through libcluster's own seams
  (the `connect`, `disconnect` and `list_nodes` MFAs of
  `Cluster.Strategy.State`) so nothing here opens a real distributed node:

    * it connects **exactly** the machines the provider reports — every one that
      has a node name and has not been declared `:gone` — and nothing else, so a
      `:pending` machine is dialled (that is how it ever becomes visible in
      `Hyper.Cluster.Budget`) while a `:gone` one is not;
    * connecting is idempotent: a machine already in the cluster is not
      re-dialled on the next poll;
    * it **never disconnects**, whatever the provider stops reporting — a machine
      mid-drain and a provider API blip are indistinguishable from here, and
      disconnecting on that signal would tear a live node's VMs out of
      `Hyper.Cluster.Routing`;
    * a listing that fails leaves the cluster alone and keeps polling, while a
      provider that cannot be built at all refuses to start the strategy rather
      than silently clustering with nothing.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Cluster.Strategy.State
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Fleet.Provider.Static
  alias Hyper.Cluster.Fleet.Strategy
  alias Unit.Time

  @moduletag :capture_log

  defmodule Peers do
    @moduledoc false
    # Stands in for distribution. `Strategy.init/1` is called inline, so every
    # one of these runs in the test process: the connected set lives in its
    # dictionary and each attempt is also posted back as a message to assert on.

    def seed(nodes), do: Process.put(__MODULE__, nodes)

    def nodes, do: Process.get(__MODULE__, [])

    def connect(node) do
      _ = seed([node | nodes()])
      send(self(), {:connect, node})
      true
    end

    def disconnect(node) do
      send(self(), {:disconnect, node})
      true
    end
  end

  defmodule ListProvider do
    @moduledoc false
    # Its whole state is the answer it gives: `provider_opts: [result: term]`.
    @behaviour Hyper.Cluster.Fleet.Provider

    @impl true
    def init(opts), do: {:ok, Keyword.fetch!(opts, :result)}

    @impl true
    def capabilities(_state), do: []

    @impl true
    def list(result), do: result

    @impl true
    def create(_state, _tags), do: {:error, :not_supported}

    @impl true
    def destroy(_state, _id), do: :ok
  end

  setup do
    # `Cluster.Strategy.connect_nodes/4` emits telemetry, which needs its table;
    # CI runs the suite with `--no-start`, so nothing else brings the app up.
    _ = Application.ensure_all_started(:telemetry)
    Peers.seed([])
    :ok
  end

  property "connects exactly the machines the provider names, skipping the ones it says are gone" do
    check all(infos <- list_of(machine(), max_length: 8)) do
      Peers.seed([])

      assert {:ok, %State{}} = Strategy.init([strategy(listing: {:ok, infos})])

      dialable =
        for %Info{node: node, status: status} <- infos,
            not is_nil(node),
            status != :gone,
            into: MapSet.new(),
            do: node

      assert MapSet.new(Peers.nodes()) == dialable
    end
  end

  test "never disconnects a node the provider has stopped reporting, and never re-dials a joined one" do
    Peers.seed([:hyper@drained, :hyper@kept])

    assert {:ok, %State{}} = Strategy.init([strategy(listing: {:ok, [active(:hyper@kept)]})])

    refute_received {:disconnect, _node}
    refute_received {:connect, _node}
  end

  test "a listing that fails leaves the cluster alone and keeps polling" do
    listing = {:error, :rate_limited}

    assert {:ok, %State{}} =
             Strategy.init([strategy(listing: listing, polling_interval: Time.ms(20))])

    assert Peers.nodes() == []
    refute_received {:disconnect, _node}
    assert_receive :poll, 500
  end

  # A topology copied out of libcluster's own documentation carries a plain
  # millisecond integer; the house style is `Unit.Time`. Both have to work, and
  # the interval is read inside `init/1` — so getting it wrong does not degrade
  # polling, it stops the strategy starting and the node never dials the fleet
  # at all.
  @intervals [
    {"a Unit.Time", Time.ms(20), :polls},
    {"libcluster's plain millisecond integer", 20, :polls},
    {"nothing at all, i.e. the built-in default", :absent, :starts}
  ]

  test "the polling interval is accepted in either notation, and may be left out" do
    for {desc, interval, expected} <- @intervals do
      result = Strategy.init([strategy(polling_interval: interval)])

      assert_polling(expected, result, desc)
    end
  end

  test "a provider that cannot be built does not start the strategy" do
    unbuildable = [provider: Static, provider_opts: [nodes: :everything]]

    assert Strategy.init([strategy(unbuildable)]) == :ignore
  end

  # The expectation arrives as an argument rather than being matched inline:
  # with the row's literal in scope the compiler narrows it to one atom and
  # reports the other clause as unreachable.
  defp assert_polling(:polls, result, desc) do
    assert {:ok, %State{}} = result, desc
    assert_receive :poll, 500
  end

  defp assert_polling(:starts, result, desc) do
    assert {:ok, %State{}} = result, desc
    refute_receive :poll, 100
  end

  # The topology as libcluster would hand it over. `overrides` come first so a
  # test can replace the provider itself, not just the listing it answers with.
  defp strategy(overrides) do
    {listing, overrides} = Keyword.pop(overrides, :listing, {:ok, []})
    {interval, overrides} = Keyword.pop(overrides, :polling_interval, Time.s(60))

    config =
      overrides ++
        [provider: ListProvider, provider_opts: [result: listing]] ++
        polling(interval)

    %State{
      topology: :fleet_test,
      connect: {Peers, :connect, []},
      disconnect: {Peers, :disconnect, []},
      list_nodes: {Peers, :nodes, []},
      config: config
    }
  end

  defp polling(:absent), do: []
  defp polling(interval), do: [polling_interval: interval]

  defp machine do
    gen all(
          id <- integer(1..64),
          node <- one_of([constant(nil), node_name()]),
          status <- member_of([:pending, :active, :error, :gone])
        ) do
      %Info{id: "m-#{id}", node: node, status: status}
    end
  end

  defp node_name, do: map(integer(1..8), &:"hyper@10.0.0.#{&1}")

  defp active(node), do: %Info{id: Atom.to_string(node), node: node, status: :active}
end
