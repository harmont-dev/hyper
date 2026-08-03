defmodule Hyper.Cluster.Fleet do
  @moduledoc """
  The set of *machines* Hyper runs on, as opposed to the microVMs that run on
  them: how many hosts exist, which of them are in the cluster, and the manual
  levers over both.

  The subsystem underneath is one process per machine, mirroring
  `Hyper.Node.FireVMM` a level up: `Hyper.Cluster.Fleet.Machine` is a
  `:gen_statem` driving a single host's lifecycle, supervised cluster-wide by
  `Hyper.Cluster.Fleet.Supervisor`; `Hyper.Cluster.Fleet.Governor` is the
  singleton that decides how many of them there should be, using the pure
  arithmetic in `Hyper.Cluster.Fleet.Policy`; and
  `Hyper.Cluster.Fleet.Provider` is the only vendor-specific code in any of it.

  This module is the human- and CLI-facing entry point, and the only place
  outside that subsystem that resolves a provider. Nothing else in the tree calls
  a provider directly — an operator asking "what does the fleet look like?"
  should get the same answer from the same source the Governor regulates
  against.

  ## The three memberships

  `machines/0` answers with every machine the provider reports *and* every node
  in the cluster, because those two sets are not the same set and the difference
  is the interesting part:

    * `:joined` — the provider reports it and its node is in
      `Hyper.Cluster.Budget`. A working machine: the scheduler can place VMs on
      it and Fleet can cordon, drain and destroy it.
    * `:pending` — the provider reports it, but its node is not in the cluster.
      Either still booting, or it booted without the cookie and configuration its
      user-data was supposed to bake in (see `Hyper.Cluster.Fleet.Strategy`), in
      which case it will be written off at `Hyper.Cfg.Fleet`'s
      `provision_deadline` and replaced.
    * `:orphan` — a node in the cluster that no reported machine accounts for.
      Hand-installed metal, a node from another deployment sharing the cookie, or
      a machine whose tags were lost at the provider. Hyper will schedule VMs
      there, but Fleet will never cordon, drain or destroy it: it has no
      controller, and a provider that does not report a machine must never be
      asked to delete it. An orphan that is *supposed* to be Fleet's is a tagging
      bug at the provider, and it is the one thing in this list worth alerting
      on.

  ## The levers

  `grow/1`, `cordon/1`, `drain/1` and `uncordon/1` sit beside the Governor rather
  than replacing it: they change the fleet, and the Governor's next tick observes
  the result and reasons from it like any other change. Draining a machine by
  hand before a kernel upgrade works identically on a fleet that autoscales and
  one that does not — `Hyper.Cluster.Fleet.Provider.Static` implements no
  mutation at all, and every lever here except `grow/1` still works on it.

  `cordon/1`, `drain/1` and `uncordon/1` name a machine by its Fleet id, so a
  typo — or a controller that migrated out from under the call — answers
  `{:error, :not_found}` rather than exiting in the caller. These are operator
  entry points; a mistyped id is the expected input, not an exceptional one.
  """

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Fleet.Machine
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Fleet.Provider
  alias Hyper.Cluster.Fleet.Supervisor, as: Controllers

  @typedoc "Where a machine stands relative to the BEAM cluster; see the moduledoc."
  @type membership :: :joined | :pending | :orphan

  @typedoc """
  One machine, as the cross of what the provider reports with what the cluster
  contains.

  `membership` decides which halves are populated: an `:orphan` is a node with no
  provider record (`id` and `info` are `nil`), anything else is a provider record
  which may not yet have a node. `id` is the Fleet identity —
  `Hyper.Cluster.Fleet.Machine.key/1`, the claim a controller created the machine
  under, falling back to the provider's own id — which is exactly what `cordon/1`,
  `drain/1` and `uncordon/1` take.
  """
  @type machine :: %{
          id: Machine.id() | nil,
          node: node() | nil,
          membership: membership(),
          info: Info.t() | nil
        }

  @doc """
  Every machine in the fleet and every node in the cluster, each classified
  `:joined`, `:pending` or `:orphan`.

  Provider records come first, in the order the provider listed them, then the
  orphaned nodes in name order. A provider that cannot be asked is an error, not
  an empty fleet: reporting "no machines" for a failed API call would read as
  "every node is an orphan", which is the opposite of the truth.
  """
  @spec machines() :: {:ok, [machine()]} | {:error, term()}
  def machines do
    with {:ok, cfg, provider_state} <- provider(),
         {:ok, infos} <- cfg.provider.list(provider_state) do
      {:ok, join(infos, members())}
    end
  end

  @doc """
  Order `count` more machines now, without waiting for the Governor to conclude
  they are needed.

  Refuses with `{:error, :not_supported}` on a provider that does not implement
  `create` — a fleet Hyper does not own is grown by whoever does own it. Returns
  as soon as the controllers are started; provisioning itself takes minutes and
  is driven by each controller against `Hyper.Cfg.Fleet`'s `provision_deadline`.
  """
  @spec grow(pos_integer()) :: :ok | {:error, term()}
  def grow(count \\ 1) when is_integer(count) and count > 0 do
    with {:ok, cfg, provider_state} <- provider(),
         :ok <- ensure_creates(cfg.provider, provider_state) do
      order(cfg, count)
    end
  end

  @doc """
  Stop new placements on `id`'s machine, leaving the VMs already on it running.

  The node stays in the cluster and keeps serving; it just stops being a
  candidate. Not persisted on the machine itself — a cordoned machine that
  reboots comes back schedulable and is re-cordoned by its controller.
  """
  @spec cordon(Machine.id()) :: :ok | {:error, term()}
  def cordon(id), do: lever(id, &Machine.cordon/1)

  @doc """
  Cordon `id`'s machine and destroy it once its VMs have ended on their own.

  VMs cannot migrate, so waiting is the only scale-in path there is; the wait is
  bounded by `Hyper.Cfg.Fleet`'s `drain_deadline`. Reversible with `uncordon/1`
  right up until the machine is destroyed.
  """
  @spec drain(Machine.id()) :: :ok | {:error, term()}
  def drain(id), do: lever(id, &Machine.drain/1)

  @doc """
  Reclaim a cordoned or draining machine: schedulable again, not destroyed.

  The cheap answer to a fleet that got busy again mid-drain — the machine is
  already paid for and already in the cluster, so taking it back beats waiting
  minutes for a new one to boot.
  """
  @spec uncordon(Machine.id()) :: :ok | {:error, term()}
  def uncordon(id), do: lever(id, &Machine.uncordon/1)

  # A controller is addressed through the routing CRDT, so it may legitimately be
  # absent (a bad id) or vanish mid-call (Horde moved it). `Hyper.stop_vm/1`
  # makes the same distinction for VMs: a name that resolves to nothing is
  # `:not_found`, everything else is reported as the exit it was.
  @spec lever(Machine.id(), (Machine.id() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  defp lever(id, fun) do
    fun.(id)
  catch
    :exit, {:noproc, _call} -> {:error, :not_found}
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc false
  # The pure half of `machines/0`: cross a provider listing with the nodes that
  # are actually in the cluster. Split out so the classification is testable
  # without a provider or a live registry.
  @spec join([Info.t()], [node()]) :: [machine()]
  def join(infos, members) do
    members = MapSet.new(members)
    listed = Enum.map(infos, &listed(&1, members))
    claimed = for %{node: node} <- listed, not is_nil(node), into: MapSet.new(), do: node

    orphans =
      members
      |> MapSet.difference(claimed)
      |> Enum.sort()
      |> Enum.map(&orphan/1)

    listed ++ orphans
  end

  @spec listed(Info.t(), MapSet.t(node())) :: machine()
  defp listed(%Info{} = info, members) do
    %{
      id: Machine.key(info),
      node: info.node,
      membership: membership(info.node, members),
      info: info
    }
  end

  @spec membership(node() | nil, MapSet.t(node())) :: :joined | :pending
  defp membership(nil, _members), do: :pending

  defp membership(node, members) do
    if MapSet.member?(members, node), do: :joined, else: :pending
  end

  @spec orphan(node()) :: machine()
  defp orphan(node), do: %{id: nil, node: node, membership: :orphan, info: nil}

  @spec members() :: [node()]
  defp members, do: Enum.map(Budget.all_states(), & &1.node)

  # Every call re-reads the configuration and re-builds the provider rather than
  # caching a client: these calls are interactive and rare, and an operator who
  # has just corrected `config.exs` expects the next one to use it.
  @spec provider() :: {:ok, Config.t(), Provider.state()} | {:error, term()}
  defp provider do
    with {:ok, cfg} <- Config.load(),
         {:ok, provider_state} <- cfg.provider.init(cfg.provider_opts) do
      {:ok, cfg, provider_state}
    end
  end

  @spec ensure_creates(module(), Provider.state()) :: :ok | {:error, :not_supported}
  defp ensure_creates(provider, provider_state) do
    if Provider.supports?(provider, provider_state, :create) do
      :ok
    else
      {:error, :not_supported}
    end
  end

  @spec order(Config.t(), pos_integer()) :: :ok | {:error, term()}
  defp order(cfg, count) do
    Enum.reduce_while(1..count, :ok, fn _nth, _acc ->
      case Controllers.start_machine(cfg, {:create, %{}}) do
        :ok -> {:cont, :ok}
        {:error, _reason} = err -> {:halt, err}
      end
    end)
  end
end
