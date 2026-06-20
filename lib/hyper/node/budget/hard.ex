defmodule Hyper.Node.Budget.Hard do
  @moduledoc """
  Node-local, authoritative ledger of this machine's **hard (alpha) budget**.

  Holds the node's total alpha capacity (memory + disk) and a set of live
  reservations. One instance runs per BEAM node, named `#{inspect(__MODULE__)}`,
  supervised by `Hyper.Node`.

  Reservations are **monitor-refcounted**, exactly like `Hyper.Node.Layer.Server`:
  `reserve/2` monitors the calling process and books its alpha; if that process dies
  the reservation is released automatically (a crashed VM cannot leak budget).
  `reserve/2` is atomic - it admits only if the node has at least the requested alpha
  free - which is why alpha stays a hard invariant without any cluster-wide locking.

  See `Hyper.Node.Budget` for why the cluster does not replicate this value.
  """

  use GenServer

  alias Hyper.Node.Budget
  alias Hyper.Node.Budget.Alpha

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            total: Alpha.t(),
            reservations: %{reference() => Alpha.t()}
          }

    @enforce_keys [:total]
    defstruct [:total, reservations: %{}]
  end

  @doc """
  Start the node's hard-budget ledger.

  Options:

    * `:total` - an `Alpha.t()` capacity. Defaults to `total_from_config/0`.
    * `:name` - registered name (atom) or `nil` for an unnamed instance (tests).
      Defaults to `#{inspect(__MODULE__)}`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc "This node's total alpha capacity."
  @spec total(GenServer.server()) :: Alpha.t()
  def total(server \\ __MODULE__), do: GenServer.call(server, :total)

  @doc "The alpha currently reserved by live VMs on this node."
  @spec used(GenServer.server()) :: Alpha.t()
  def used(server \\ __MODULE__), do: GenServer.call(server, :used)

  @doc "The alpha still free on this node: `total - used`."
  @spec avail(GenServer.server()) :: Alpha.t()
  def avail(server \\ __MODULE__), do: GenServer.call(server, :avail)

  @doc """
  Atomically reserve `need` alpha on behalf of the **calling** process.

  Admits only if the node currently has at least `need` free (`{:ok, ref}`);
  otherwise `{:error, :insufficient}` and the ledger is untouched. The caller is
  monitored: if it dies the reservation is released automatically. Pass the
  returned `ref` to `release/2` to give the budget back early.
  """
  @spec reserve(GenServer.server(), Alpha.t()) :: {:ok, reference()} | {:error, :insufficient}
  def reserve(server \\ __MODULE__, %Alpha{} = need) do
    GenServer.call(server, {:reserve, need, self()})
  end

  @doc "Release the reservation identified by `ref`. No-op for an unknown ref."
  @spec release(GenServer.server(), reference()) :: :ok
  def release(server \\ __MODULE__, ref) when is_reference(ref) do
    GenServer.call(server, {:release, ref})
  end

  @doc """
  This node's declared total alpha capacity, from application config:

      config :hyper, #{inspect(__MODULE__)},
        mem: <bytes>, disk: <bytes>
  """
  @spec total_from_config() :: Alpha.t()
  def total_from_config do
    cfg = Application.get_env(:hyper, __MODULE__, [])
    mem = Keyword.fetch!(cfg, :mem)
    disk = Keyword.fetch!(cfg, :disk)
    %Alpha{mem: Unit.Information.bytes(mem), disk: Unit.Information.bytes(disk)}
  end

  @doc """
  Readiness check: this node can only run VMs if its total alpha capacity is
  declared. Returns `{:error, :budget_unconfigured}` when `:mem`/`:disk` are
  missing from `config :hyper, #{inspect(__MODULE__)}`.
  """
  @spec test_system() :: :ok | {:error, :budget_unconfigured}
  def test_system do
    cfg = Application.get_env(:hyper, __MODULE__, [])

    if Keyword.has_key?(cfg, :mem) and Keyword.has_key?(cfg, :disk) do
      :ok
    else
      {:error, :budget_unconfigured}
    end
  end

  @impl true
  def init(opts) do
    total = Keyword.get_lazy(opts, :total, &total_from_config/0)
    {:ok, %State{total: total}}
  end

  @impl true
  def handle_call(:total, _from, %State{total: total} = state) do
    {:reply, total, state}
  end

  @impl true
  def handle_call(:used, _from, state) do
    {:reply, sum_used(state), state}
  end

  @impl true
  def handle_call(:avail, _from, %State{total: total} = state) do
    {:reply, Budget.sub(total, sum_used(state)), state}
  end

  @impl true
  def handle_call({:reserve, need, owner}, _from, %State{total: total} = state) do
    if Budget.fits?(Budget.sub(total, sum_used(state)), need) do
      ref = Process.monitor(owner)
      state = %{state | reservations: Map.put(state.reservations, ref, need)}
      {:reply, {:ok, ref}, state}
    else
      {:reply, {:error, :insufficient}, state}
    end
  end

  @impl true
  def handle_call({:release, ref}, _from, state) do
    {:reply, :ok, drop(state, ref)}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {:noreply, drop(state, ref)}
  end

  # Sum of every live reservation. Named `sum_used` (not `used`) to avoid
  # colliding with the public `used/1` client function.
  @spec sum_used(State.t()) :: Alpha.t()
  defp sum_used(%State{reservations: reservations}) do
    Enum.reduce(Map.values(reservations), Budget.zero(), &Budget.add(&2, &1))
  end

  # Remove the reservation keyed by `ref` (no-op if absent) and stop monitoring.
  @spec drop(State.t(), reference()) :: State.t()
  defp drop(%State{reservations: reservations} = state, ref) do
    case Map.pop(reservations, ref) do
      {nil, _} ->
        state

      {_alpha, reservations} ->
        Process.demonitor(ref, [:flush])
        %{state | reservations: reservations}
    end
  end
end
