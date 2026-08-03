defmodule Hyper.Node.Cordon do
  @moduledoc """
  This node's drain flag: *no new work here*.

  Cordoning means what it means in every other scheduler: the node stops being a
  placement candidate, while every microVM already running on it keeps running,
  untouched. It is not a shutdown, and it kills nothing.

  It exists because a firecracker microVM is welded to its host and cannot
  migrate (see `Hyper.Node`, which is why VMs sit under a *local*
  `DynamicSupervisor`). Since a VM cannot be moved off a machine, the only way to
  empty one is to stop sending it new VMs and wait for the ones it has to exit.
  Cordoning is the "stop sending" half, and so it is the first step of every
  scale-in decision `Hyper.Cluster.Fleet` makes. It is equally useful with
  autoscaling switched off: cordon a machine by hand, wait for it to empty, then
  reboot it into a new kernel without ever killing someone's VM.

  `Hyper.Node.Budget.NodeState.build/0` reads the flag and it rides out to the
  rest of the cluster on the existing `Hyper.Node.Budget.Advertiser` heartbeat,
  where `NodeState.fits?/2` short-circuits to `false`. Propagation therefore
  costs a heartbeat plus CRDT lag: a cordon is *not* instantaneous cluster-wide,
  and a VM can still land here inside that window. Anything draining a machine
  must poll until it is actually empty rather than assume the VM count only ever
  falls.

  ## Deliberately not persisted

  A rebooted machine comes back **uncordoned**, and so does a node whose
  `Hyper.Node` subtree restarted this process. That is a decision, not an
  oversight: the flag records an intent held by whoever set it, and after a
  reboot nothing on this node can know whether that intent still stands. An
  operator draining by hand would far rather find a rebooted machine schedulable
  than find it silently quarantined forever by a flag nobody remembers setting.

  Re-asserting is therefore the *watcher's* job, not this module's. The machine's
  `Hyper.Cluster.Fleet.Machine` controller re-asserts on its own poll while it
  holds the machine in `:cordoned` or `:draining`, and reads the flag back when
  it adopts a node — which is why `set/1` is idempotent and drops a write that
  changes nothing (see below): re-asserting has to cost nothing, because it
  happens on a timer. With no controller (autoscaling off, a hand-installed
  node), nothing re-asserts and a reboot clears the cordon; an operator draining
  such a node by hand should expect to cordon it again afterwards.

  ## Why `:persistent_term` behind a `GenServer`

  Reads are on the advertiser's heartbeat path and on any future "may I take
  work?" path, so they must never queue behind a writer: `:persistent_term.get/2`
  is a lock-free read of a globally shared term, with no message and no copy, and
  it answers even when this process is not running - `NodeState.build/0` cannot
  be broken by a cordon restart.

  Writes go through this process rather than straight at `:persistent_term` for
  two reasons. They are serialised, so two concurrent cordon/uncordon calls
  cannot interleave. And a write that changes nothing is dropped here, before it
  reaches `:persistent_term`, whose updates force a global scan for references to
  the old term - which matters because a machine's controller re-cordons on a
  poll, and steady state must cost nothing.

  Owning the term in a process also gives the flag a lifetime: it is initialised
  to "not cordoned" when `Hyper.Node` starts and erased when it stops, so a fresh
  supervision tree never inherits a stale flag from the previous one.
  """

  use GenServer

  @key __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Set or clear this node's cordon.

  Synchronous: once this returns, every `drained?/0` on this node reports
  `value`. Idempotent - setting the flag to what it already holds is a no-op, so
  a regulator may re-assert a cordon on every tick.
  """
  @spec set(boolean()) :: :ok
  def set(value) when is_boolean(value), do: GenServer.call(__MODULE__, {:set, value})

  @doc """
  Whether this node is cordoned, i.e. refusing *new* placements.

  Reports the flag and nothing else. In particular it says nothing about whether
  the node still hosts VMs - that question is answered by counting this node's
  entries in `Hyper.Cluster.Routing`.
  """
  @spec drained?() :: boolean()
  def drained?, do: :persistent_term.get(@key, false)

  @impl true
  def init(_opts) do
    # Trapping exits so `terminate/2` runs on a supervisor shutdown: the flag
    # must not outlive the process that owns it.
    Process.flag(:trap_exit, true)
    :ok = :persistent_term.put(@key, false)
    {:ok, false}
  end

  @impl true
  def handle_call({:set, current}, _from, current), do: {:reply, :ok, current}

  def handle_call({:set, value}, _from, _current) do
    :ok = :persistent_term.put(@key, value)
    {:reply, :ok, value}
  end

  @impl true
  def terminate(_reason, _state) do
    _ = :persistent_term.erase(@key)
    :ok
  end
end
