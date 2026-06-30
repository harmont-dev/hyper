defmodule Hyper.Node.Reaper do
  @moduledoc """
  Per-node periodic, liveness-aware garbage collector for per-VM host resources
  that an unclean BEAM death can strand: a firecracker cgroup leaf and a
  `hyper-rw-<id>` dm volume whose owning processes' `terminate/2` never ran and
  whose vm_id never reboots (so `Hyper.Node.Reclaim`, which runs once at boot, and
  the relaunch-time cleanup in the FireVMM path, never get a chance to clear it).

  Liveness is the whole point. The reaper consults two independent sources of
  truth for "this vm is alive" (`Plan.orphans/3` removes their union from the
  candidate set) and only ever touches `hyper-rw-*` dm names and per-VM cgroup
  leaves - never `hyper-thinpool`, `hyper-img-*`, or a live VM's resources. A
  candidate must also survive two consecutive ticks (`Plan.confirm/2`) before it
  is reaped, so a VM caught mid-boot (resources present, not yet registered) is
  given a grace tick rather than destroyed.

  The decision logic lives in the pure `Hyper.Node.Reaper.Plan`; this module is a
  thin I/O adapter that gathers the inputs, calls the plan, and executes the
  best-effort, idempotent removals.
  """

  use GenServer
  use OpenTelemetryDecorator
  require Logger

  alias Hyper.Cluster.Routing
  alias Hyper.Node.FireVMM.Jailer
  alias Hyper.Node.Img
  alias Hyper.Node.Reaper.Plan
  alias Hyper.SuidHelper.{ChrootJail, Dmsetup}

  @vm_sup Hyper.Node.VMSupervisor

  # Rest between reap ticks. Deliberately not configurable: the two-strike
  # confirmation (`Plan.confirm/2`) already means an orphan is reaped at most one
  # interval after it is first seen, so the exact value is not load-bearing.
  @interval Unit.Time.s(60)

  defstruct last_orphans: MapSet.new()

  @type t :: %__MODULE__{last_orphans: MapSet.t(String.t())}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:tick, state) do
    state = sweep(state)
    schedule()
    {:noreply, state}
  end

  # Ignore any unexpected message (port noise, stale timers) rather than crashing.
  def handle_info(_msg, state), do: {:noreply, state}

  @spec schedule() :: reference()
  defp schedule do
    Process.send_after(self(), :tick, Unit.Time.as_ms(@interval))
  end

  @spec sweep(t()) :: t()
  @decorate with_span("Hyper.Node.Reaper.sweep")
  defp sweep(%__MODULE__{} = state) do
    live = gather_live()
    leaves = list_cgroup_leaves()
    rw = Plan.rw_ids(list_rw_dm())

    current = Plan.orphans(live, leaves, rw)
    {to_reap, next} = Plan.confirm(current, state.last_orphans)

    Enum.each(to_reap, &reap_one/1)
    %{state | last_orphans: next}
  end

  # Over-counting "live" only defers a reap (safe); under-counting destroys a live
  # VM (catastrophic). So union two independent liveness sources: the local VM
  # supervisor's children and the cluster routing table's view of this node.
  @spec gather_live() :: MapSet.t(String.t())
  defp gather_live, do: MapSet.union(local_live(), routed_live())

  @spec local_live() :: MapSet.t(String.t())
  defp local_live do
    case Process.whereis(@vm_sup) do
      nil ->
        MapSet.new()

      _pid ->
        @vm_sup
        |> DynamicSupervisor.which_children()
        |> Enum.map(fn {_, child, _, _} -> child end)
        |> Enum.filter(&is_pid/1)
        |> Enum.map(&Routing.id_for/1)
        |> Enum.reject(&is_nil/1)
        |> MapSet.new()
    end
  end

  @spec routed_live() :: MapSet.t(String.t())
  defp routed_live do
    for {id, node} <- Routing.all(), node == node(), into: MapSet.new(), do: id
  end

  @spec list_cgroup_leaves() :: [String.t()]
  defp list_cgroup_leaves do
    parent = Jailer.cgroup_parent_dir()

    case File.ls(parent) do
      {:ok, names} ->
        # The parent holds the per-VM leaf directories alongside cgroup control
        # files (`cgroup.procs`, `cgroup.controllers`, ...); only the directories
        # are vm_id leaves.
        Enum.filter(names, &File.dir?(Path.join(parent, &1)))

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("reaper: could not list cgroup leaves: #{inspect(reason)}")
        []
    end
  end

  @spec list_rw_dm() :: [String.t()]
  defp list_rw_dm do
    case Dmsetup.list() do
      {:ok, names} ->
        names

      {:error, reason} ->
        Logger.warning("reaper: could not list dm devices: #{inspect(reason)}")
        []
    end
  end

  @spec reap_one(String.t()) :: :ok
  @decorate with_span("Hyper.Node.Reaper.reap_one", include: [:id])
  defp reap_one(id) do
    Logger.warning("reaper: reaping orphan vm #{id}")

    log_result(
      "chroot/cgroup",
      id,
      ChrootJail.remove(Jailer.chroot_dir(id), Jailer.cgroup_dir(id))
    )

    log_result("dm volume", id, Dmsetup.remove(Img.Mutable.dm_name(id)))
    :ok
  end

  @spec log_result(String.t(), String.t(), :ok | {:error, term()}) :: :ok
  defp log_result(_what, _id, :ok), do: :ok

  defp log_result(what, id, {:error, reason}) do
    Logger.warning("reaper: removing #{what} for #{id} failed: #{inspect(reason)}")
  end
end
