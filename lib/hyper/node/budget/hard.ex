defmodule Hyper.Node.Budget.Hard do
  @moduledoc """
  Hard per-node resource accounting. One `Hard` runs per BEAM node (named
  `__MODULE__`, started under `Hyper.Node.Budget.Supervisor`) and tracks how much
  memory and disk the VMs scheduled onto this machine have reserved.

  "Hard" means the limits are inviolable: a reservation that would push the
  running total past the node's configured `mem_max`/`disk_max`
  (`Hyper.Cfg.Budget`) is refused outright. Callers reserve through
  `with_budget/2`, which holds the budget for the duration of the callback and
  releases it afterwards.
  """

  use GenServer
  use Unit.Operators
  use OpenTelemetryDecorator

  alias Hyper.Cfg.Budget, as: Config
  alias Hyper.Vm.Instance

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            mem_allocated: Unit.Information.t(),
            disk_allocated: Unit.Information.t(),
            reservations: %{reference() => Hyper.Vm.Instance.Spec.t()}
          }

    defstruct [:mem_allocated, :disk_allocated, reservations: %{}]

    use Unit.Operators

    @spec zero() :: t()
    def zero do
      %__MODULE__{
        mem_allocated: Unit.Information.zero(),
        disk_allocated: Unit.Information.zero()
      }
    end

    @doc "Add `spec`'s reservation to the running total."
    @spec bump(t(), Instance.Spec.t()) :: t()
    def bump(s, spec) do
      %{
        s
        | mem_allocated: s.mem_allocated + spec.mem,
          disk_allocated: s.disk_allocated + spec.disk
      }
    end

    @doc "Release `spec`'s reservation from the running total."
    @spec cut(t(), Instance.Spec.t()) :: t()
    def cut(s, spec) do
      %{
        s
        | mem_allocated: s.mem_allocated - spec.mem,
          disk_allocated: s.disk_allocated - spec.disk
      }
    end

    @doc "Record that monitor `ref` owns `spec`'s reservation."
    @spec track(t(), reference(), Hyper.Vm.Instance.Spec.t()) :: t()
    def track(s, ref, spec), do: %{s | reservations: Map.put(s.reservations, ref, spec)}

    @doc "Drop monitor `ref`, returning the spec it owned (or nil) and the new state."
    @spec untrack(t(), reference()) :: {Hyper.Vm.Instance.Spec.t() | nil, t()}
    def untrack(s, ref) do
      {spec, rest} = Map.pop(s.reservations, ref)
      {spec, %{s | reservations: rest}}
    end
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Can this node run the given vm spec? `:ok` if yes, `{:error, reason}` otherwise."
  @spec can_run(Instance.Spec.t()) :: :ok | {:error, term()}
  @decorate with_span("Hyper.Node.Budget.Hard.can_run", include: [:vm_spec])
  def can_run(vm_spec) do
    GenServer.call(__MODULE__, {:can_run, vm_spec})
  end

  @doc """
  Reserve `vm_spec`'s budget, run `callable`, and release the budget afterwards.

  Returns `callable`'s value if the reservation succeeds, or `{:error, reason}`
  if the node cannot fit the spec. The budget is released even if `callable`
  raises.
  """
  @spec with_budget(Instance.Spec.t(), (-> result)) :: result | {:error, term()}
        when result: var
  @decorate with_span("Hyper.Node.Budget.Hard.with_budget", include: [:vm_spec])
  def with_budget(vm_spec, callable) do
    with :ok <- GenServer.call(__MODULE__, {:ingest, vm_spec}) do
      try do
        callable.()
      after
        GenServer.call(__MODULE__, {:egress, vm_spec})
      end
    end
  end

  @doc """
  Reserve `spec`'s budget for the lifetime of `owner`.

  Atomic: refuses (`{:error, reason}`) if `spec` does not fit remaining headroom.
  On success the reservation releases automatically when `owner` dies.
  """
  @spec reserve(Instance.Spec.t(), pid()) :: :ok | {:error, term()}
  @decorate with_span("Hyper.Node.Budget.Hard.reserve", include: [:spec])
  def reserve(spec, owner), do: GenServer.call(__MODULE__, {:reserve, spec, owner})

  @doc "Configured caps minus what is currently reserved."
  @spec headroom() :: %{mem: Unit.Information.t(), disk: Unit.Information.t()}
  @decorate with_span("Hyper.Node.Budget.Hard.headroom")
  def headroom, do: GenServer.call(__MODULE__, :headroom)

  # Server callbacks

  @impl true
  def init(_opts) do
    {:ok, State.zero()}
  end

  @impl true
  def handle_call({:can_run, spec}, _from, state) do
    {:reply, fits(state, spec), state}
  end

  @impl true
  def handle_call({:ingest, spec}, _from, state) do
    case fits(state, spec) do
      :ok -> {:reply, :ok, State.bump(state, spec)}
      {:error, _} = err -> {:reply, err, state}
    end
  end

  @impl true
  def handle_call({:egress, spec}, _from, state) do
    {:reply, :ok, State.cut(state, spec)}
  end

  @impl true
  def handle_call({:reserve, spec, owner}, _from, state) do
    case fits(state, spec) do
      :ok ->
        ref = Process.monitor(owner)
        state = state |> State.bump(spec) |> State.track(ref, spec)
        republish()
        {:reply, :ok, state}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:headroom, _from, state) do
    config = Config.get()

    headroom = %{
      mem: config.mem_max - state.mem_allocated,
      disk: config.disk_max - state.disk_allocated
    }

    {:reply, headroom, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case State.untrack(state, ref) do
      {nil, state} ->
        {:noreply, state}

      {spec, state} ->
        republish()
        {:noreply, State.cut(state, spec)}
    end
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # Re-publish this node's NodeState after any reservation change. Guarded so
  # Hard runs standalone when no advertiser is present.
  @spec republish() :: :ok
  defp republish do
    case Process.whereis(Hyper.Node.Budget.Advertiser) do
      nil -> :ok
      _pid -> Hyper.Node.Budget.Advertiser.publish()
    end
  end

  # Whether reserving `spec` keeps both totals within the node's configured caps.
  @spec fits(State.t(), Instance.Spec.t()) :: :ok | {:error, term()}
  defp fits(state, spec) do
    config = Config.get()

    cond do
      state.mem_allocated + spec.mem > config.mem_max -> {:error, :mem_exhausted}
      state.disk_allocated + spec.disk > config.disk_max -> {:error, :disk_exhausted}
      true -> :ok
    end
  end
end
