defmodule Hyper.Cluster.Fleet.Supervisor do
  @moduledoc """
  Supervises one `Hyper.Cluster.Fleet.Machine` controller per machine in the
  fleet. A `Horde.DynamicSupervisor` with `members: :auto`, so the set of
  controllers is spread across the cluster and survives the loss of any one node
  in it.

  ## Why this one is Horde and `Hyper.Node`'s is not

  `Hyper.Node.VMSupervisor` is deliberately a **local** `DynamicSupervisor`:

  > a firecracker VM is pinned to this machine's kernel/rootfs/cgroup/tap
  > devices and cannot migrate, so we deliberately avoid
  > `Horde.DynamicSupervisor` (which would try to restart VMs on a surviving
  > node - cold-booting a ghost).

  This supervisor is the principled inverse of that decision, and it is the same
  argument run the other way. What is supervised here is not the machine, it is
  the *controller that watches* the machine. A microVM exists only while the host
  process that owns its devices does, so restarting it elsewhere resurrects
  nothing. A machine exists at the provider whether or not any BEAM node is
  looking at it — and keeps costing money either way — so losing the node that
  watched it must **not** lose the controller: the machine would still be there,
  still be billed, and no longer be cordonable, drainable or destroyable by
  anyone. Migration is a bug for VMs and a requirement for machines.

  ## A migrated controller re-adopts; it does not resume

  Horde does not hand process state over. When a member dies, a survivor drops
  the dead node's entry and starts the child again from the `start` MFA recorded
  in its child spec: same arguments, fresh process, no phase, no deadlines, no
  provider state carried across. `Hyper.Cluster.Fleet.Machine`'s child spec is
  therefore written as an *adoption seed* — the provider, its options and the
  machine's claim, never the phase the previous controller happened to be in — so
  a restarted controller re-reads the machine from the provider and re-enters the
  lifecycle wherever the machine actually is. Encoding "create one" in those
  arguments would make every migration buy a second machine; that is why
  adoption is the ordinary path through `Hyper.Cluster.Fleet.Machine` rather than
  a special case bolted onto it.

  ## Uniqueness comes from the registry, not from the child id

  Horde randomises a child's id on every `start_child` and again on hand-off, so
  two controllers for one machine — the worst bug available in this subsystem —
  cannot be prevented by a stable id here. It is prevented one level down, by
  `Hyper.Cluster.Routing.register_self/1` on `{:machine, id}` in the controller's
  `init`: the loser returns `:ignore`, and Horde records no child for an
  `:ignore`. `start_machine/2` therefore treats `:ignore` as success — it means
  the machine already has a controller, which is the outcome it wanted.

  ## Restart policy

  Children are `:transient`: a controller that finished `:terminating` exits
  `{:shutdown, _}` and Horde removes it from the CRDT permanently, while one that
  crashed comes back and re-adopts. Note that restart intensity is shared by
  every child on a node and blowing it takes this whole supervisor down with it —
  which is why a controller absorbs a failing provider with its own backoff state
  instead of crashing.
  """

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Cluster.Fleet.Machine

  @name __MODULE__

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    Horde.DynamicSupervisor.child_spec(name: @name, strategy: :one_for_one, members: :auto)
  end

  @doc """
  Start the controller for one machine, somewhere in the cluster.

  `entry` is how the controller enters the lifecycle: `{:create, tags}` to order
  a new machine, `{:adopt, info}` to take over one the provider already reports.
  Both are recorded in the child spec Horde replays on restart and hand-off (see
  the moduledoc).

  `:ok` also covers "this machine already has a controller" — the identity
  guarantee refusing a duplicate is the desired end state, not a failure.

  `supervisor` names the `Horde.DynamicSupervisor` to start under; it exists so
  `Hyper.Cluster.Fleet.Governor` can be driven against a supervisor of its own in
  tests without owning a second copy of the answer mapping above.
  """
  @spec start_machine(Config.t(), Machine.entry(), atom()) :: :ok | {:error, term()}
  def start_machine(%Config{} = cfg, entry, supervisor \\ @name) do
    spec = Machine.child_spec(cfg: cfg, entry: entry)

    case Horde.DynamicSupervisor.start_child(supervisor, spec) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _info} -> :ok
      :ignore -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
