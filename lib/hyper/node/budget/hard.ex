defmodule Hyper.Node.Budget.Hard do
  @moduledoc """
  Hard per-node resource accounting. One `Hard` runs per BEAM node (named
  `__MODULE__`, started under `Hyper.Node.Budget.Supervisor`) and tracks how much
  memory and disk this machine's VMs hold.

  Capacity is granted *before* a VM boots. `lease/2` reserves against the placing
  caller and returns a token; the VM then converts that lease into a reservation
  of its own via `claim/2` from inside `Hyper.Node.FireVMM.init/1`, and the
  caller drops its token. A lease counts against the caps exactly like a
  reservation, so a concurrent herd cannot all pass admission and then boot into
  memory nothing has taken.

  A lease is released by three independent mechanisms, because no one of them
  covers every failure:

    * the **monitor** on the leasing process — a crash, in microseconds;
    * the **`boot_lease_ttl`** — a caller that is alive but wedged, which no
      monitor will ever fire for;
    * `drop/2` — the normal path, once the boot has finished either way.

  When a claimed owner dies its reservation becomes a lease again for
  `restart_grace`, so a `:transient` VM restart re-claims the same capacity
  rather than racing a competing placement for it.
  """

  use GenServer
  use Unit.Operators
  use OpenTelemetryDecorator

  alias Hyper.Cfg.Budget, as: Config
  alias Hyper.Vm.Instance

  defmodule State do
    @moduledoc """
    Pure ledger for one node's hard budget. One entry per vm_id, in one of two
    kinds:

      * `{:leased, spec, token, expires_at}` — capacity granted to a boot that
        has not happened yet. Revocable by `drop/3` with the matching token, or
        by `expire/2` once `expires_at` passes.
      * `{:claimed, spec, owner_ref}` — capacity held by a live VM. Immune to
        `drop/3` and to `expire/2`; released only via `release/3`, which turns
        it back into a short-lived lease so a supervisor restart leaves no gap.

    Both kinds occupy capacity. That is the invariant admission rests on: a VM
    that is about to exist must be as visible to `lease/5` as one that already
    is.

    Pure — no processes and no clock. `expires_at`, and the `now` passed to
    `expire/2`, are monotonic milliseconds supplied by the caller.
    """

    use Unit.Operators

    alias Hyper.Vm.Instance.Spec
    alias Unit.Information

    @type token :: reference()
    @type caps :: %{mem: Information.t(), disk: Information.t()}
    @type entry ::
            {:leased, Spec.t(), token(), integer()}
            | {:claimed, Spec.t(), reference()}
    @type t :: %__MODULE__{entries: %{Hyper.Vm.Id.t() => entry()}}

    defstruct entries: %{}

    @spec new() :: t()
    def new, do: %__MODULE__{}

    @doc "Memory and disk held by every entry, leased and claimed alike."
    @spec allocated(t()) :: caps()
    def allocated(%__MODULE__{entries: entries}) do
      Enum.reduce(entries, %{mem: Information.zero(), disk: Information.zero()}, fn
        {_vm_id, entry}, acc ->
          spec = spec_of(entry)
          %{mem: acc.mem + spec.mem, disk: acc.disk + spec.disk}
      end)
    end

    @doc """
    Grant `spec`'s capacity to `vm_id` provisionally, expiring at `expires_at`.

    Refuses `:already_held` rather than overwriting: a vm_id is unique per VM,
    so a second lease is a bug, and silently replacing a claimed entry would
    leave a live VM unaccounted.
    """
    @spec lease(t(), Hyper.Vm.Id.t(), Spec.t(), caps(), integer()) ::
            {:ok, token(), t()} | {:error, :mem_exhausted | :disk_exhausted | :already_held}
    def lease(%__MODULE__{entries: entries} = state, vm_id, spec, caps, expires_at) do
      if Map.has_key?(entries, vm_id) do
        {:error, :already_held}
      else
        with :ok <- fits(state, spec, caps) do
          token = make_ref()
          entry = {:leased, spec, token, expires_at}
          {:ok, token, %{state | entries: Map.put(entries, vm_id, entry)}}
        end
      end
    end

    @doc """
    Convert `vm_id`'s lease into a reservation owned by `owner_ref`.

    Never refuses on capacity — that was granted at lease time, and refusing
    here would leave a booted VM with no accounting. Re-claiming an already
    claimed vm_id rebinds it to the new owner (a `:transient` VM restart).
    """
    @spec claim(t(), Hyper.Vm.Id.t(), reference()) :: {:ok, t()} | {:error, :no_lease}
    def claim(%__MODULE__{entries: entries} = state, vm_id, owner_ref) do
      case Map.fetch(entries, vm_id) do
        {:ok, entry} ->
          entry = {:claimed, spec_of(entry), owner_ref}
          {:ok, %{state | entries: Map.put(entries, vm_id, entry)}}

        :error ->
          {:error, :no_lease}
      end
    end

    @doc """
    Release `vm_id`'s lease, if `token` still matches it.

    A no-op on a claimed entry and on a lease that has since been re-issued with
    a fresh token, so a placing caller's late `drop` can never take capacity out
    from under a live VM.
    """
    @spec drop(t(), Hyper.Vm.Id.t(), token()) :: t()
    def drop(%__MODULE__{entries: entries} = state, vm_id, token) do
      case Map.fetch(entries, vm_id) do
        {:ok, {:leased, _spec, ^token, _expires_at}} ->
          %{state | entries: Map.delete(entries, vm_id)}

        _other ->
          state
      end
    end

    @doc """
    Turn `vm_id`'s reservation back into a lease expiring at `expires_at`.

    Called when a claimed owner dies. The capacity stays held for the grace
    window so a `:transient` restart can re-claim it, and the fresh token
    invalidates any `drop` still in flight from the original placement.
    """
    @spec release(t(), Hyper.Vm.Id.t(), integer()) :: t()
    def release(%__MODULE__{entries: entries} = state, vm_id, expires_at) do
      case Map.fetch(entries, vm_id) do
        {:ok, {:claimed, spec, _owner_ref}} ->
          entry = {:leased, spec, make_ref(), expires_at}
          %{state | entries: Map.put(entries, vm_id, entry)}

        _other ->
          state
      end
    end

    @doc "Drop every lease whose deadline has passed. Reservations are untouched."
    @spec expire(t(), integer()) :: {[Hyper.Vm.Id.t()], t()}
    def expire(%__MODULE__{entries: entries} = state, now) do
      expired =
        for {vm_id, {:leased, _spec, _token, expires_at}} <- entries,
            expires_at <= now,
            do: vm_id

      {Enum.sort(expired), %{state | entries: Map.drop(entries, expired)}}
    end

    @doc "The vm_id whose reservation `owner_ref` owns, or nil."
    @spec vm_id_for_owner(t(), reference()) :: Hyper.Vm.Id.t() | nil
    def vm_id_for_owner(%__MODULE__{entries: entries}, owner_ref) do
      Enum.find_value(entries, fn
        {vm_id, {:claimed, _spec, ^owner_ref}} -> vm_id
        _other -> nil
      end)
    end

    @spec fits(t(), Spec.t(), caps()) :: :ok | {:error, :mem_exhausted | :disk_exhausted}
    defp fits(state, spec, caps) do
      %{mem: mem, disk: disk} = allocated(state)

      cond do
        mem + spec.mem > caps.mem -> {:error, :mem_exhausted}
        disk + spec.disk > caps.disk -> {:error, :disk_exhausted}
        true -> :ok
      end
    end

    @spec spec_of(entry()) :: Spec.t()
    defp spec_of({:leased, spec, _token, _expires_at}), do: spec
    defp spec_of({:claimed, spec, _owner_ref}), do: spec
  end

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Grant `spec`'s capacity to `vm_id` provisionally, held against the calling
  process and expiring after `boot_lease_ttl`.

  Returns a token for `drop/2`. Refuses if `spec` does not fit what is left.
  """
  @spec lease(Hyper.Vm.Id.t(), Instance.Spec.t()) :: {:ok, State.token()} | {:error, term()}
  @decorate with_span("Hyper.Node.Budget.Hard.lease", include: [:vm_id, :spec])
  def lease(vm_id, spec), do: GenServer.call(__MODULE__, {:lease, vm_id, spec, self()})

  @doc """
  Convert `vm_id`'s lease into a reservation owned by `owner`, released when
  `owner` dies. Never refuses on capacity.
  """
  @spec claim(Hyper.Vm.Id.t(), pid()) :: :ok | {:error, :no_lease}
  @decorate with_span("Hyper.Node.Budget.Hard.claim", include: [:vm_id])
  def claim(vm_id, owner), do: GenServer.call(__MODULE__, {:claim, vm_id, owner})

  @doc "Release the lease `token` identifies. A no-op once the VM has claimed it."
  @spec drop(Hyper.Vm.Id.t(), State.token()) :: :ok
  @decorate with_span("Hyper.Node.Budget.Hard.drop", include: [:vm_id])
  def drop(vm_id, token), do: GenServer.call(__MODULE__, {:drop, vm_id, token})

  @doc "Configured caps minus what is currently leased or reserved."
  @spec headroom() :: %{mem: Unit.Information.t(), disk: Unit.Information.t()}
  @decorate with_span("Hyper.Node.Budget.Hard.headroom")
  def headroom, do: GenServer.call(__MODULE__, :headroom)

  # Server callbacks

  defmodule Server do
    @moduledoc false
    @type t :: %__MODULE__{
            ledger: State.t(),
            leasers: %{reference() => {Hyper.Vm.Id.t(), State.token()}}
          }
    defstruct ledger: nil, leasers: %{}
  end

  @impl true
  def init(_opts), do: {:ok, %Server{ledger: State.new()}}

  @impl true
  def handle_call({:lease, vm_id, spec, leaser}, _from, s) do
    ttl_ms = Unit.Time.as_ms(Config.get().boot_lease_ttl)

    case State.lease(s.ledger, vm_id, spec, caps(), now_ms() + ttl_ms) do
      {:ok, token, ledger} ->
        ref = Process.monitor(leaser)
        _ = Process.send_after(self(), :sweep, ttl_ms)
        republish()

        {:reply, {:ok, token},
         %{s | ledger: ledger, leasers: Map.put(s.leasers, ref, {vm_id, token})}}

      {:error, _reason} = err ->
        {:reply, err, s}
    end
  end

  @impl true
  def handle_call({:claim, vm_id, owner}, _from, s) do
    owner_ref = Process.monitor(owner)

    case State.claim(s.ledger, vm_id, owner_ref) do
      {:ok, ledger} ->
        republish()
        {:reply, :ok, %{s | ledger: ledger, leasers: forget_leaser(s.leasers, vm_id)}}

      {:error, :no_lease} = err ->
        Process.demonitor(owner_ref, [:flush])
        {:reply, err, s}
    end
  end

  @impl true
  def handle_call({:drop, vm_id, token}, _from, s) do
    ledger = State.drop(s.ledger, vm_id, token)

    # A drop carrying a stale token changes nothing, and must not retire the
    # leaser's monitor — that monitor is still the lease's release path.
    if ledger == s.ledger do
      {:reply, :ok, s}
    else
      republish()
      {:reply, :ok, %{s | ledger: ledger, leasers: forget_leaser(s.leasers, vm_id)}}
    end
  end

  @impl true
  def handle_call(:headroom, _from, s) do
    caps = caps()
    %{mem: mem, disk: disk} = State.allocated(s.ledger)
    {:reply, %{mem: caps.mem - mem, disk: caps.disk - disk}, s}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, s), do: {:noreply, handle_down(s, ref)}

  @impl true
  def handle_info(:sweep, s) do
    {expired, ledger} = State.expire(s.ledger, now_ms())
    _ = if expired != [], do: republish()
    {:noreply, %{s | ledger: ledger, leasers: forget_leasers(s.leasers, expired)}}
  end

  @impl true
  def handle_info(_msg, s), do: {:noreply, s}

  # A :DOWN is either the process that took a lease, or the owner of a claimed
  # reservation. A leaser's death drops its lease outright; an owner's death
  # converts the reservation back into a grace lease so a `:transient` restart
  # can re-claim the same capacity.
  @spec handle_down(Server.t(), reference()) :: Server.t()
  defp handle_down(s, ref) do
    case Map.pop(s.leasers, ref) do
      {{vm_id, token}, leasers} ->
        republish()
        %{s | ledger: State.drop(s.ledger, vm_id, token), leasers: leasers}

      {nil, _leasers} ->
        release_owner(s, ref)
    end
  end

  @spec release_owner(Server.t(), reference()) :: Server.t()
  defp release_owner(s, ref) do
    case State.vm_id_for_owner(s.ledger, ref) do
      nil ->
        s

      vm_id ->
        grace_ms = Unit.Time.as_ms(Config.get().restart_grace)
        _ = Process.send_after(self(), :sweep, grace_ms)
        republish()
        %{s | ledger: State.release(s.ledger, vm_id, now_ms() + grace_ms)}
    end
  end

  @spec forget_leaser(%{reference() => {Hyper.Vm.Id.t(), State.token()}}, Hyper.Vm.Id.t()) ::
          %{reference() => {Hyper.Vm.Id.t(), State.token()}}
  defp forget_leaser(leasers, vm_id), do: forget_leasers(leasers, [vm_id])

  @spec forget_leasers(%{reference() => {Hyper.Vm.Id.t(), State.token()}}, [Hyper.Vm.Id.t()]) ::
          %{reference() => {Hyper.Vm.Id.t(), State.token()}}
  defp forget_leasers(leasers, vm_ids) do
    gone = MapSet.new(vm_ids)

    Enum.reduce(leasers, %{}, fn {ref, {vm_id, token}}, acc ->
      if MapSet.member?(gone, vm_id) do
        Process.demonitor(ref, [:flush])
        acc
      else
        Map.put(acc, ref, {vm_id, token})
      end
    end)
  end

  # Re-publish this node's NodeState after any reservation change. Guarded so
  # Hard runs standalone when no advertiser is present.
  @spec republish() :: :ok
  defp republish do
    case Process.whereis(Hyper.Node.Budget.Advertiser) do
      nil -> :ok
      _pid -> Hyper.Node.Budget.Advertiser.publish()
    end
  end

  @spec caps() :: State.caps()
  defp caps do
    config = Config.get()
    %{mem: config.mem_max, disk: config.disk_max}
  end

  @spec now_ms() :: integer()
  defp now_ms, do: System.monotonic_time(:millisecond)
end
