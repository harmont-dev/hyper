defmodule Hyper.Cluster.Fleet.Machine do
  @moduledoc """
  `:gen_statem` controller for exactly one machine — the host-level mirror of
  `Hyper.Node.FireVMM.State`, one level up. `FireVMM` supervises one microVM and
  drives its lifecycle from a statem; Fleet supervises one *host* the same way.

  The edges, all of them:

      :requested --> :provisioning --> :awaiting_join --> :ready
      :provisioning --> :failed --> :requested                 (bounded retry)
      :ready --> :cordoned --> :draining                       (scale-in)
      :cordoned --> :ready and :draining --> :ready            (reclaim)
      :ready | :cordoned | :draining --> :unreachable --> back, or :terminating
      :awaiting_join | :draining | :unreachable --> :terminating --> stopped

  Phases:

    * `:requested`     - we owe the provider a machine. Reconcile against
                         `Provider.list/1` first (see *claiming* below), then
                         hand `Provider.create/2` to a monitored task.
    * `:provisioning`  - that create is in flight. Slow (minutes) and allowed to
                         fail; a failure goes to `:failed`, and the provision
                         deadline writes the machine off.
    * `:failed`        - backoff between create attempts. A provider outage must
                         never be expressed as a crash loop: Horde counts restart
                         intensity across *every* child on a node, so one
                         crash-looping controller would take down the whole fleet
                         supervisor. Backoff belongs here, in a state.
    * `:awaiting_join` - the machine exists; wait for its node to appear in
                         `Hyper.Cluster.Budget.all_states/0`. That membership is
                         the *only* readiness probe — it means the BEAM booted,
                         Hyper started and the scheduler can place work there,
                         which no provider health endpoint can tell us.
    * `:ready`         - joined and schedulable. `Node.monitor/2` is armed here.
    * `:unreachable`   - the node went down. A grace timer; recovery returns to
                         whichever phase we left, expiry asks the *provider*
                         whether the machine is still there and writes it off
                         only if the provider agrees it is not (see below).
    * `:cordoned`      - `Hyper.Node.Cordon.set/1` has been set on the node, so
                         its gossiped `NodeState` stops accepting placements.
                         Stable, but not passive: the cordon is re-asserted on a
                         poll, because the flag is deliberately not persisted on
                         the far side and a reboot (or a restart of that node's
                         `Hyper.Node.Cordon`) clears it. This is also the manual
                         "drain before a kernel upgrade" state, and a machine
                         parked here is never destroyed on its own.
    * `:draining`      - cordoned *and* counting down: poll
                         `Hyper.Cluster.Routing.all/0` until no VM runs on the
                         node, then terminate. VMs cannot migrate, so waiting is
                         the only scale-in path there is.
    * `:terminating`   - `Provider.destroy/2` (idempotent), then stop.

  ## Identity, and why creation is claimed

  The controller registers itself in `Hyper.Cluster.Routing` under
  `{:machine, id}` from `init`, through `Hyper.Cluster.Routing.register_self/1`
  (never a `{:via, _}` name at `start_link` — see the OTP/Horde race documented
  there). That registration is the *only* thing preventing two controllers for
  one machine, which is the worst bug available here: Horde randomises child ids
  on every `start_child` and again on handoff, so a stable child spec id
  guarantees nothing. A controller that loses the race returns `:ignore`, which
  Horde records without writing a CRDT entry.

  `id` is the machine's Fleet identity and it must exist *before* the machine
  does, because `Provider.create/2` is the one operation that cannot be made
  idempotent by the provider. So a create-mode controller mints a claim, carries
  it in the tags the machine is created with, and `key/1` reads it back out of
  any observed `Info`. Two consequences fall out:

    * a controller that crashes or migrates mid-create replays the same claim
      (it is baked into the child spec args by `child_spec/1`), re-enters
      `:requested`, finds its own machine in `Provider.list/1` and adopts it
      instead of paying for a second one;
    * a machine whose creation outlived its controller entirely is still tagged,
      so it is visible to `Provider.list/1` and adoptable rather than an orphan.

  Adopted machines have no claim and use the provider's own id. Adoption is not
  a special case anywhere in this module — it is the same code path that Horde
  handoff, a full-cluster restart and pre-existing metal all take.

  ## Nothing survives a migration

  Unlike a microVM, a machine is not pinned to the node watching it (that is the
  principled inverse of the comment in `Hyper.Node`), so `Fleet.Supervisor` is a
  `Horde.DynamicSupervisor` and this controller migrates when its node dies.
  Horde replays the stored `{__MODULE__, :start_link, [args]}` verbatim: phase,
  deadlines, failure counters and the provider's state are all lost. The start
  args must therefore be a complete re-adoption seed and never encode a
  transient phase — `cfg` (which carries the provider module and its options, so
  `Provider.init/1` can simply be re-run) plus an `entry` that is either an
  `{:adopt, info}` observation or a *claimed* `{:create, tags}`.

  ## Deliberate policies

  **Nothing is destroyed while VMs are running on it.** Killing customer
  workloads to reclaim a host is not a trade Fleet is allowed to make, and the
  rule is enforced on the *destroy edge* rather than on each of the four paths
  that reach it: `:terminating` counts `Hyper.Cluster.Routing.all/0` first and,
  finding work, turns the termination into a drain instead. When
  `drain_deadline` then lapses with VMs still present the machine falls back to
  `:cordoned`: it keeps its work, keeps taking none, and stops being the drain
  the fleet is waiting on — the Governor is free to pick another.

  **A machine is only given up on if it can be replaced.** The provision deadline
  and the nodedown grace both end in `:terminating` — but only when
  `capabilities/1` includes `:create`. Under an observe-only provider those
  deadlines would trade a machine the operator declared for nothing at all, so
  they lapse into an indefinite wait instead: a declared node that is down is a
  node that is expected back.

  **Losing contact is not evidence that a machine is gone.** A network partition
  looks exactly like a dead machine from the wrong end of it: the node vanishes
  from `Hyper.Cluster.Budget` (Horde prunes an unreachable member's
  registrations), its VMs vanish from `Hyper.Cluster.Routing` with it, and
  `{:nodedown, _}` fires — while on the other side the machine is serving those
  VMs perfectly well. So an expired nodedown grace does not destroy anything by
  itself: it re-lists the provider, and a machine the provider still calls
  `:pending` or `:active` is kept and re-checked one grace period later, however
  long that takes. The cost of being wrong in that direction is a machine that
  keeps being billed while the fleet grows a replacement around it; the cost of
  being wrong in the other direction is somebody's running VMs. Only a provider
  that reports `:error`, `:gone` or nothing at all lets the write-off through.

  The residual case this cannot cover is a machine that never joined *and* is
  reported healthy: a controller adopted onto the minority side of a partition
  cannot tell it from a machine that booted without the cluster cookie, and the
  provision deadline writes both off. Adoption is driven by
  `Hyper.Cluster.Fleet.Governor`, which refuses to regulate a cluster it cannot
  see itself in — that narrows the window rather than closing it.

  **An unreachable node is treated as already cordoned.** `Hyper.Node.Cordon` is
  reached by `:erpc`, and a node we cannot reach has already lost its
  `Hyper.Cluster.Budget` entry, so it takes no placements either way. A failure
  of that call — transport, a peer too old to have the module, a `Cordon`
  mid-restart — is therefore reported and treated as success rather than
  crashing the controller into Horde's *shared* restart budget. The converse
  matters more: cordon state is deliberately not persisted on the far side, so
  `:cordoned` and `:draining` re-assert it on their own poll, and a controller
  that adopts an already-cordoned node reads the flag back rather than assuming
  `:ready`.
  """

  @behaviour :gen_statem

  require Logger

  alias Hyper.Cfg.Fleet, as: Config
  alias Hyper.Cluster.Budget
  alias Hyper.Cluster.Fleet.Machine
  alias Hyper.Cluster.Fleet.Machine.Info
  alias Hyper.Cluster.Fleet.Provider
  alias Hyper.Cluster.Routing
  alias Unit.Time

  alias __MODULE__.{
    AwaitingJoin,
    Cordoned,
    Draining,
    Failed,
    Provisioning,
    Ready,
    Requested,
    Terminating,
    Unreachable
  }

  @typedoc """
  A machine's Fleet identity: the claim of the controller that created it, or the
  provider's own id for a machine that was adopted. See `key/1`.
  """
  @type id :: String.t()

  @typedoc "How a controller enters the lifecycle."
  @type entry :: {:create, Info.tags()} | {:adopt, Info.t()}

  @typedoc "The lifecycle phase; the `:gen_statem` state."
  @type phase ::
          :requested
          | :provisioning
          | :failed
          | :awaiting_join
          | :ready
          | :unreachable
          | :cordoned
          | :draining
          | :terminating

  @typedoc "What `describe/1` answers."
  @type summary :: %{
          id: id(),
          provider_id: Info.id() | nil,
          node: node() | nil,
          phase: phase(),
          tags: Info.tags()
        }

  @enforce_keys [:cfg, :id, :tags]
  defstruct [
    :cfg,
    :id,
    :tags,
    :provider_state,
    :provider_id,
    :node,
    :deadline,
    :resume,
    :creator,
    failures: 0
  ]

  @type t :: %Machine{
          cfg: Config.t(),
          id: id(),
          tags: Info.tags(),
          provider_state: Provider.state() | nil,
          provider_id: Info.id() | nil,
          node: node() | nil,
          deadline: integer() | nil,
          resume: phase() | nil,
          creator: {pid(), reference()} | nil,
          failures: non_neg_integer()
        }

  # The tag a create-mode controller writes its claim into. Namespaced because it
  # lands in the operator's own tag space at the provider.
  @claim_tag "hyper.fleet.claim"

  # How often to re-ask a question whose answer we cannot be pushed: cluster
  # membership while waiting to join or recover, the VM count while draining,
  # and — because the far side's flag does not survive a reboot — the cordon.
  @join_poll Time.s(5)
  @recover_poll Time.s(5)
  @drain_poll Time.s(10)
  @cordon_poll Time.s(30)

  # A wedged peer must not pin the controller: `:erpc.call/4` would wait forever,
  # and the Governor gives up on a controller that will not describe itself.
  @cordon_timeout Time.s(5)

  # Backoff between create attempts, and between destroy attempts.
  @retry_base Time.s(5)
  @retry_max Time.s(60)
  @destroy_attempts 5

  @doc """
  Child spec for `Hyper.Cluster.Fleet.Supervisor`.

  Options are `:cfg` (a `t:Hyper.Cfg.Fleet.t/0`, which carries the provider and
  its options) and `:entry`. A `{:create, tags}` entry is *claimed* here rather
  than in `init`, so the claim is part of the args Horde replays on restart and
  handoff — that is what makes re-entering `:requested` an adoption instead of a
  second machine.

  `:transient`, so a controller that reached `:terminating` stays dead (it exits
  `{:shutdown, _}`, which Horde removes from the CRDT) while a crashed one
  restarts and re-adopts.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    entry = opts |> Keyword.fetch!(:entry) |> claim()

    %{
      id: {__MODULE__, identity(entry)},
      start: {__MODULE__, :start_link, [Keyword.put(opts, :entry, entry)]},
      restart: :transient
    }
  end

  @doc "Start a controller. See `child_spec/1` for the options."
  @spec start_link(keyword()) :: {:ok, pid()} | :ignore | {:error, term()}
  def start_link(opts) do
    :gen_statem.start_link(__MODULE__, opts, [])
  end

  @doc """
  The Fleet identity of an observed machine: the claim it carries if it was
  created by a controller, else the provider's own id.

  The Governor keys its adoption on this, so that a machine created under a claim
  is recognised as already having a controller.
  """
  @spec key(Info.t()) :: id()
  def key(%Info{id: id, tags: tags}), do: Map.get(tags, @claim_tag, id)

  @doc "Cluster-wide name of the controller for `id`."
  @spec via(id()) :: {:via, module(), {atom(), term()}}
  def via(id), do: Routing.via({:machine, id})

  @doc "Stop new placements on this machine, leaving its running VMs alone."
  @spec cordon(id()) :: :ok | {:error, term()}
  def cordon(id), do: :gen_statem.call(via(id), :cordon)

  @doc """
  Cordon, then wait for the machine's VMs to end and destroy it.

  This is scale-in. It is reversible right up to the moment the last VM leaves:
  `uncordon/1` reclaims a draining machine, which is always cheaper than
  provisioning a replacement for one that is already paid for and already joined.
  """
  @spec drain(id()) :: :ok | {:error, term()}
  def drain(id), do: :gen_statem.call(via(id), :drain)

  @doc "Reclaim a cordoned or draining machine: schedulable again, not destroyed."
  @spec uncordon(id()) :: :ok | {:error, term()}
  def uncordon(id), do: :gen_statem.call(via(id), :uncordon)

  @doc "What this controller currently knows about its machine."
  @spec describe(id()) :: summary()
  def describe(id), do: :gen_statem.call(via(id), :describe)

  @impl :gen_statem
  def callback_mode do
    :handle_event_function
  end

  @impl :gen_statem
  def init(opts) do
    cfg = Keyword.fetch!(opts, :cfg)
    entry = opts |> Keyword.fetch!(:entry) |> claim()
    id = identity(entry)

    case Routing.register_self({:machine, id}) do
      :ok -> enter(cfg, entry, id)
      {:error, {:already_registered, _pid}} -> :ignore
    end
  end

  # A provider whose options no longer build (a rotated credential, a removed
  # region) is a configuration fault, not a machine fault: `:ignore` leaves no
  # CRDT entry behind, so the Governor simply retries on its next tick instead of
  # this controller entering Horde's shared restart-intensity budget.
  @spec enter(Config.t(), entry(), id()) :: {:ok, phase(), t(), list()} | :ignore
  defp enter(cfg, entry, id) do
    case cfg.provider.init(cfg.provider_opts) do
      {:ok, provider_state} ->
        data = %Machine{cfg: cfg, id: id, tags: tags(entry), provider_state: provider_state}
        start_phase(entry, data)

      {:error, reason} ->
        Logger.error("fleet machine #{id}: provider init failed: #{inspect(reason)}")
        :ignore
    end
  end

  @spec start_phase(entry(), t()) :: {:ok, phase(), t(), list()}
  defp start_phase({:create, _tags}, data) do
    data = with_deadline(data, data.cfg.provision_deadline)
    {:ok, :requested, data, [{:state_timeout, 0, :reconcile}]}
  end

  defp start_phase({:adopt, %Info{} = info}, data) do
    {phase, data, actions} = observed(info, with_deadline(data, data.cfg.provision_deadline))
    {:ok, phase, data, actions}
  end

  @impl :gen_statem
  # Answered in every phase: an operator asking what a machine is doing must get
  # an answer while it is provisioning or draining, not only when it is ready.
  def handle_event({:call, from}, :describe, phase, data) do
    summary = %{
      id: data.id,
      provider_id: data.provider_id,
      node: data.node,
      phase: phase,
      tags: data.tags
    }

    {:keep_state_and_data, [{:reply, from, summary}]}
  end

  # Losing the node is a phase change in three phases and noise everywhere else
  # (a monitor fires at most once, but a controller can be re-adopted into a
  # phase that never armed one). `resume` is what makes recovery return to the
  # phase we were actually in rather than assuming `:ready`.
  def handle_event(:info, {:nodedown, down}, phase, %Machine{node: down} = data)
      when phase in [:ready, :cordoned, :draining] do
    Logger.warning(
      "fleet machine #{data.id}: node #{down} is down; " <>
        "#{Time.as_s(data.cfg.nodedown_grace)}s grace before it is written off"
    )

    data = %{with_deadline(data, data.cfg.nodedown_grace) | resume: phase}
    {:next_state, :unreachable, data, [{:state_timeout, 0, :poll}]}
  end

  def handle_event(type, content, phase, data) do
    module = handler(phase)
    module.handle(type, content, data)
  end

  @spec handler(phase()) :: module()
  defp handler(:requested), do: Requested
  defp handler(:provisioning), do: Provisioning
  defp handler(:failed), do: Failed
  defp handler(:awaiting_join), do: AwaitingJoin
  defp handler(:ready), do: Ready
  defp handler(:unreachable), do: Unreachable
  defp handler(:cordoned), do: Cordoned
  defp handler(:draining), do: Draining
  defp handler(:terminating), do: Terminating

  @doc false
  # The phase an observation puts us in. Shared by `init` (adoption), by
  # `:requested` (reconcile found our claim) and by `:provisioning` (create
  # answered), because those are the same event: "the provider has told us what
  # this machine is". Note that `:pending` and `:active` land in the same place -
  # we never ask the provider whether a machine is ready, only whether it exists.
  @spec observed(Info.t(), t()) :: {phase(), t(), list()}
  def observed(%Info{} = info, %Machine{} = data) do
    data = %{
      data
      | provider_id: info.id,
        node: info.node || data.node,
        tags: Map.merge(data.tags, info.tags)
    }

    case info.status do
      status when status in [:pending, :active] ->
        {:awaiting_join, data, [{:state_timeout, 0, :poll}]}

      :gone ->
        Logger.warning("fleet machine #{data.id}: provider reports it gone; retiring it")
        {:terminating, %{data | failures: 0, deadline: nil}, [{:state_timeout, 0, :destroy}]}

      :error ->
        broken(data)
    end
  end

  # `:error` means "this machine will never become usable" — replace it — and a
  # machine that is being replaced is still a machine that may be running VMs
  # right now. A vendor flag flipping (host maintenance, a degraded array) must
  # therefore start a *drain*, not a delete, whenever the machine is part of the
  # cluster; only one that never joined and holds nothing goes straight out.
  @spec broken(t()) :: {phase(), t(), list()}
  defp broken(data) do
    if joined?(data) or vms_on(data.node) > 0 do
      Logger.warning("fleet machine #{data.id}: provider reports it broken; draining it")
      draining(data)
    else
      Logger.warning("fleet machine #{data.id}: provider reports it broken; replacing it")
      {:terminating, %{data | failures: 0, deadline: nil}, [{:state_timeout, 0, :destroy}]}
    end
  end

  @doc false
  # Every call a phase does not implement is refused with the phase that refused
  # it, and every message it does not expect is dropped. Monitor noise and stale
  # timers must never crash a controller: a crash is a restart, and restarts are
  # a shared, fleet-wide budget under Horde.
  @spec unhandled(tuple() | atom(), term(), t(), phase()) ::
          :keep_state_and_data | {:keep_state_and_data, list()}
  def unhandled({:call, from}, _content, _data, phase) do
    {:keep_state_and_data, [{:reply, from, {:error, {:invalid_in, phase}}}]}
  end

  def unhandled(_type, _content, _data, _phase), do: :keep_state_and_data

  @doc false
  # One retry step. Bounded not by a count but by the provision deadline: the
  # question an operator asked was "how long may a machine take to become
  # useful", and a create that keeps failing spends that same budget.
  @spec retry(t(), term()) :: {:next_state, phase(), t(), list()}
  def retry(%Machine{} = data, reason) do
    data = %{data | failures: data.failures + 1}

    if lapsed?(data) do
      Logger.warning(
        "fleet machine #{data.id}: giving up after #{data.failures} attempt(s): " <>
          "#{inspect(reason)}"
      )

      {:next_state, :terminating, %{data | failures: 0, deadline: nil},
       [{:state_timeout, 0, :destroy}]}
    else
      delay = backoff(data.failures)
      Logger.warning("fleet machine #{data.id}: #{inspect(reason)}; retrying in #{delay}ms")
      {:next_state, :failed, data, [{:state_timeout, delay, :retry}]}
    end
  end

  @doc false
  # The decision `:awaiting_join` makes at its deadline: keep waiting, or stop
  # waiting. (`:unreachable` asks a harder question — see `Unreachable` — because
  # it is giving up on a machine that was working, not on one that never was.)
  #
  # Stopping only makes sense when the fleet can replace what it gives up. In an
  # observe-only fleet the machines are the operator's declaration, not Fleet's
  # to retire - a node that is down is a node that will come back, and this
  # controller's job is to be waiting when it does. So a lapsed deadline there
  # clears itself (logging once) and the poll continues indefinitely.
  @spec keep_waiting(t(), String.t(), non_neg_integer()) ::
          {:keep_state, t(), list()} | {:next_state, phase(), t(), list()}
  def keep_waiting(%Machine{} = data, why, poll) do
    cond do
      not lapsed?(data) ->
        {:keep_state, data, [{:state_timeout, poll, :poll}]}

      supports?(data, :create) ->
        write_off(data, why)

      true ->
        Logger.warning(
          "fleet machine #{data.id}: #{why}, but the provider cannot replace it; " <>
            "keeping the controller and waiting"
        )

        {:keep_state, %{data | deadline: nil}, [{:state_timeout, poll, :poll}]}
    end
  end

  @doc false
  # Write the machine off: whatever it is, it is not going to become useful.
  @spec write_off(t(), String.t()) :: {:next_state, phase(), t(), list()}
  def write_off(%Machine{} = data, why) do
    Logger.warning("fleet machine #{data.id}: #{why}; terminating it")

    {:next_state, :terminating, %{data | failures: 0, deadline: nil},
     [{:state_timeout, 0, :destroy}]}
  end

  @doc false
  @spec claim_tag() :: String.t()
  def claim_tag, do: @claim_tag

  @doc false
  @spec join_poll() :: non_neg_integer()
  def join_poll, do: Time.as_ms(@join_poll)

  @doc false
  @spec recover_poll() :: non_neg_integer()
  def recover_poll, do: Time.as_ms(@recover_poll)

  @doc false
  @spec drain_poll() :: non_neg_integer()
  def drain_poll, do: Time.as_ms(@drain_poll)

  @doc false
  @spec cordon_poll() :: non_neg_integer()
  def cordon_poll, do: Time.as_ms(@cordon_poll)

  @doc false
  @spec destroy_attempts() :: pos_integer()
  def destroy_attempts, do: @destroy_attempts

  @doc false
  @spec with_deadline(t(), Unit.Time.t()) :: t()
  def with_deadline(%Machine{} = data, budget) do
    %{data | deadline: System.monotonic_time(:millisecond) + Time.as_ms(budget)}
  end

  @doc false
  @spec lapsed?(t()) :: boolean()
  def lapsed?(%Machine{deadline: nil}), do: false
  def lapsed?(%Machine{deadline: at}), do: System.monotonic_time(:millisecond) >= at

  @doc false
  @spec remaining(t()) :: timeout()
  def remaining(%Machine{deadline: nil}), do: :infinity

  def remaining(%Machine{deadline: at}) when is_integer(at),
    do: max(at - System.monotonic_time(:millisecond), 0)

  @doc false
  # Exponential, capped, and capped again in the exponent so a long-lived
  # controller cannot overflow it into a nonsense delay.
  @spec backoff(non_neg_integer()) :: pos_integer()
  def backoff(failures) when is_integer(failures) and failures >= 0 do
    min(Time.as_ms(@retry_base) * Integer.pow(2, min(failures, 8)), Time.as_ms(@retry_max))
  end

  @doc false
  @spec supports?(t(), Provider.capability()) :: boolean()
  def supports?(%Machine{} = data, capability) do
    Provider.supports?(data.cfg.provider, data.provider_state, capability)
  end

  @doc false
  # Our machine as the provider currently sees it, matched by Fleet identity so a
  # claimed machine is found before it has ever been adopted.
  @spec claimed(t()) :: {:ok, Info.t()} | :absent | {:error, term()}
  def claimed(%Machine{} = data) do
    case data.cfg.provider.list(data.provider_state) do
      {:ok, infos} ->
        case Enum.find(infos, &(key(&1) == data.id)) do
          nil -> :absent
          %Info{} = info -> {:ok, info}
        end

      {:error, _reason} = err ->
        err
    end
  end

  @doc false
  # Cluster membership is the readiness probe; see the moduledoc.
  @spec joined?(t()) :: boolean()
  def joined?(%Machine{node: nil}), do: false
  def joined?(%Machine{node: node}), do: Enum.any?(Budget.all_states(), &(&1.node == node))

  @doc false
  @spec vms_on(node() | nil) :: non_neg_integer()
  def vms_on(node), do: Enum.count(Routing.all(), fn {_vm_id, on} -> on == node end)

  @doc false
  # Best effort by design: a node whose cordon cannot be set is a node we cannot
  # reach, and one we cannot reach has already lost its `Hyper.Cluster.Budget`
  # entry, so it takes no placements either way.
  @spec set_cordon(t(), boolean()) :: :ok | :unreachable
  def set_cordon(%Machine{node: nil}, _drain), do: :unreachable

  def set_cordon(%Machine{node: node} = data, drain) do
    case remote(node, :set, [drain]) do
      {:ok, _answer} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "fleet machine #{data.id}: cannot set cordon=#{drain} on #{node} " <>
            "(#{inspect(reason)}); an unreachable node is already unschedulable"
        )

        :unreachable
    end
  end

  @doc false
  # The far side's own answer, never our memory of it: the flag is not persisted
  # there, so a machine that rebooted (or whose `Hyper.Node.Cordon` restarted)
  # comes back schedulable no matter what this controller last asked for. A node
  # that will not answer is read as uncordoned - it is already unschedulable for
  # want of a budget entry, and `uncordon/1` re-asserts unconditionally.
  @spec cordoned?(t()) :: boolean()
  def cordoned?(%Machine{node: nil}), do: false

  def cordoned?(%Machine{node: node}) do
    case remote(node, :drained?, []) do
      {:ok, drained} when is_boolean(drained) -> drained
      _other -> false
    end
  end

  # Every failure mode of a remote call is a fleet observation, never a crash:
  # `:erpc.call/5` raises `:error` for a remote error (`:undef` on a peer running
  # a release without `Hyper.Node.Cordon`) and `:exit` for a remote exit (a
  # `Cordon` mid-restart answering `:noproc`, or one too slow to answer at all),
  # and a controller that crashes spends restart intensity every other controller
  # on this node shares.
  @spec remote(node(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  defp remote(node, fun, args) do
    if reachable?(node) do
      {:ok, :erpc.call(node, Hyper.Node.Cordon, fun, args, Time.as_ms(@cordon_timeout))}
    else
      {:error, :not_distributed}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # A BEAM that never joined distribution can still answer for itself, and can
  # never answer for anyone else.
  @spec reachable?(node()) :: boolean()
  defp reachable?(node), do: node == node() or Node.alive?()

  @doc false
  # A BEAM that is not distributed cannot monitor anything - and has no cluster
  # for a machine to have joined either, so there is nothing to lose.
  @spec watch(node() | nil) :: :ok
  def watch(nil), do: :ok

  def watch(node) do
    if Node.alive?() do
      _ = Node.monitor(node, true)
      :ok
    else
      :ok
    end
  end

  @doc false
  # Joined, and therefore schedulable - unless the node itself says otherwise.
  # The cordon is read back rather than assumed, because a controller reaches
  # here by adoption as often as by provisioning: a crash or a Horde hand-off
  # mid-drain would otherwise leave a node advertising `drain: true` under a
  # controller that believes it is `:ready`, which is capacity paid for and
  # permanently unusable.
  @spec enter_ready(t()) :: {:next_state, phase(), t()} | {:next_state, phase(), t(), list()}
  def enter_ready(%Machine{} = data) do
    :ok = watch(data.node)
    data = %{data | deadline: nil, resume: nil, failures: 0}

    if cordoned?(data) do
      Logger.info("fleet machine #{data.id}: #{data.node} joined the cluster, still cordoned")
      enter_cordoned(data)
    else
      Logger.info("fleet machine #{data.id}: #{data.node} joined the cluster")
      {:next_state, :ready, data}
    end
  end

  @doc false
  # Held back from placement, and *kept* held back: the poll re-asserts a flag
  # the far side does not persist.
  @spec enter_cordoned(t(), list()) :: {:next_state, phase(), t(), list()}
  def enter_cordoned(%Machine{} = data, actions \\ []) do
    {:next_state, :cordoned, %{data | deadline: nil},
     actions ++ [{:state_timeout, cordon_poll(), :poll}]}
  end

  @doc false
  @spec enter_draining(t(), list()) :: {:next_state, phase(), t(), list()}
  def enter_draining(%Machine{} = data, actions \\ []) do
    {phase, data, own} = draining(data)
    {:next_state, phase, data, actions ++ own}
  end

  @doc false
  # Cordon now, count later: the flag has to be in place before the first count,
  # or the count is of a machine still taking new work.
  @spec draining(t()) :: {phase(), t(), list()}
  def draining(%Machine{} = data) do
    _ = set_cordon(data, true)
    {:draining, with_deadline(data, data.cfg.drain_deadline), [{:state_timeout, 0, :poll}]}
  end

  @spec claim(entry()) :: entry()
  defp claim({:create, tags}), do: {:create, Map.put_new_lazy(tags, @claim_tag, &mint/0)}
  defp claim({:adopt, %Info{}} = entry), do: entry

  @spec identity(entry()) :: id()
  defp identity({:create, tags}), do: Map.fetch!(tags, @claim_tag)
  defp identity({:adopt, %Info{} = info}), do: key(info)

  @spec tags(entry()) :: Info.tags()
  defp tags({:create, tags}), do: tags
  defp tags({:adopt, %Info{tags: tags}}), do: tags

  @spec mint() :: id()
  defp mint, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  defmodule Requested do
    @moduledoc """
    We owe the provider a machine. Reconcile, then create; advance to
    `:provisioning`.
    """

    require Logger

    alias Hyper.Cluster.Fleet.Machine
    alias Hyper.Cluster.Fleet.Machine.Info

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:state_timeout, :reconcile, data) do
      case Machine.claimed(data) do
        # Our claim already names a machine: a previous incarnation of this
        # controller created it before it died. Adopt, never re-create.
        {:ok, %Info{} = info} ->
          {phase, data, actions} = Machine.observed(info, data)
          {:next_state, phase, data, actions}

        :absent ->
          create(data)

        {:error, reason} ->
          Machine.retry(data, {:list, reason})
      end
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :requested)

    # A provider that cannot create is not a failure to retry, it is a
    # misconfiguration: the Governor should never have asked. Stop cleanly rather
    # than burn the provision deadline on a refusal that will not change.
    @spec create(Machine.t()) ::
            {:next_state, Machine.phase(), Machine.t(), list()}
            | {:stop, term(), Machine.t()}
    defp create(data) do
      if Machine.supports?(data, :create) do
        {:next_state, :provisioning, spawn_create(data),
         [{:state_timeout, Machine.remaining(data), :deadline}]}
      else
        Logger.error("fleet machine #{data.id}: provider cannot create machines")
        {:stop, {:shutdown, :create_unsupported}, data}
      end
    end

    # `create/2` may block for minutes, so it runs in a task and the controller
    # stays responsive to its own deadline. Monitored but deliberately not linked:
    # a create that outlives its controller must not take the controller with it,
    # and the machine it produces carries our claim, so it is adoptable rather
    # than orphaned.
    @spec spawn_create(Machine.t()) :: Machine.t()
    defp spawn_create(data) do
      parent = self()
      provider = data.cfg.provider
      provider_state = data.provider_state
      tags = data.tags

      {pid, ref} =
        spawn_monitor(fn ->
          send(parent, {:created, self(), provider.create(provider_state, tags)})
        end)

      %{data | creator: {pid, ref}}
    end
  end

  defmodule Provisioning do
    @moduledoc "`Provider.create/2` is in flight. Advance on its answer, or fail."

    alias Hyper.Cluster.Fleet.Machine
    alias Hyper.Cluster.Fleet.Machine.Info

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:info, {:created, pid, result}, %{creator: {pid, ref}} = data) do
      _ = Process.demonitor(ref, [:flush])
      data = %{data | creator: nil}

      case result do
        {:ok, %Info{} = info} ->
          {phase, data, actions} = Machine.observed(info, data)
          {:next_state, phase, data, actions}

        {:error, reason} ->
          Machine.retry(data, {:create, reason})
      end
    end

    def handle(:info, {:DOWN, ref, :process, pid, reason}, %{creator: {pid, ref}} = data) do
      Machine.retry(%{data | creator: nil}, {:create_crashed, reason})
    end

    # The deadline can lapse with a create still running. It keeps running: it is
    # holding a provider request we cannot cancel, and whatever it produces
    # carries our claim, so `Provider.list/1` makes it adoptable rather than lost.
    def handle(:state_timeout, :deadline, data) do
      Machine.retry(data, :provision_timeout)
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :provisioning)
  end

  defmodule Failed do
    @moduledoc "Backing off between create attempts. Returns to `:requested`."

    alias Hyper.Cluster.Fleet.Machine

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:state_timeout, :retry, data) do
      {:next_state, :requested, data, [{:state_timeout, 0, :reconcile}]}
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :failed)
  end

  defmodule AwaitingJoin do
    @moduledoc "The machine exists. Wait for its node to appear in `Hyper.Cluster.Budget`."

    alias Hyper.Cluster.Fleet.Machine

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:state_timeout, :poll, data) do
      if Machine.joined?(data) do
        Machine.enter_ready(data)
      else
        Machine.keep_waiting(
          learn_node(data),
          "has not joined the cluster before its provision deadline",
          Machine.join_poll()
        )
      end
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :awaiting_join)

    # A provider that cannot name a machine's node up front may be able to later
    # (a DNS record, an assigned address). Only asked while the name is unknown,
    # because without it there is nothing to wait for and no way to recognise the
    # join. A machine missing from `list/1` is *not* treated as vanished here: it
    # is more often a provider that has not caught up with its own create, and
    # the deadline already covers a machine that truly never appears.
    @spec learn_node(Machine.t()) :: Machine.t()
    defp learn_node(%{node: nil} = data) do
      case Machine.claimed(data) do
        {:ok, info} -> %{data | node: info.node, provider_id: info.id}
        _other -> data
      end
    end

    defp learn_node(data), do: data
  end

  defmodule Ready do
    @moduledoc "Joined and schedulable. Accepts `cordon`, `drain` and `uncordon`."

    alias Hyper.Cluster.Fleet.Machine

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle({:call, from}, :cordon, data) do
      _ = Machine.set_cordon(data, true)
      Machine.enter_cordoned(data, [{:reply, from, :ok}])
    end

    def handle({:call, from}, :drain, data) do
      Machine.enter_draining(data, [{:reply, from, :ok}])
    end

    # Asserted, not assumed. This phase is also where a controller lands after
    # every restart and hand-off, so "we never cordoned it" says nothing about
    # what the node itself is advertising - and this is the operator's only lever
    # for a node stuck advertising a cordon nobody remembers setting.
    def handle({:call, from}, :uncordon, data) do
      _ = Machine.set_cordon(data, false)
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :ready)
  end

  defmodule Unreachable do
    @moduledoc """
    The node is gone *as far as this side can see*. Recover to the phase we left,
    or — only with the provider's agreement — write the machine off.

    Losing BEAM contact is the one observation this module refuses to act on
    alone: it is what a partition looks like from the minority side, and the
    machine on the other side of one is still running its VMs. See the
    corroboration policy in `Hyper.Cluster.Fleet.Machine`.
    """

    require Logger

    alias Hyper.Cluster.Fleet.Machine
    alias Hyper.Cluster.Fleet.Machine.Info

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:state_timeout, :poll, data) do
      cond do
        Machine.joined?(data) -> recover(data)
        not Machine.lapsed?(data) -> {:keep_state, data, [{:state_timeout, poll(), :poll}]}
        true -> expired(data)
      end
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :unreachable)

    # The grace is spent, so the node is not coming back by itself. What that is
    # worth depends on who else can see the machine.
    @spec expired(Machine.t()) ::
            {:keep_state, Machine.t(), list()}
            | {:next_state, Machine.phase(), Machine.t(), list()}
    defp expired(data) do
      if Machine.supports?(data, :create) do
        corroborate(data)
      else
        wait(data, "is unreachable, but the provider cannot replace it")
      end
    end

    # The provider is the only witness available that is not this node.
    @spec corroborate(Machine.t()) ::
            {:keep_state, Machine.t(), list()}
            | {:next_state, Machine.phase(), Machine.t(), list()}
    defp corroborate(data) do
      case Machine.claimed(data) do
        {:ok, %Info{status: status}} when status in [:pending, :active] ->
          wait(data, "is unreachable from here, but the provider still reports it #{status}")

        {:ok, %Info{status: status}} ->
          Machine.write_off(data, "is unreachable and the provider reports it #{status}")

        :absent ->
          Machine.write_off(data, "is unreachable and the provider no longer lists it")

        {:error, reason} ->
          wait(data, "is unreachable and the provider cannot be asked (#{inspect(reason)})")
      end
    end

    # Keep the controller and keep polling, but re-arm the grace so the machine
    # is re-corroborated once per grace period rather than once per poll — and so
    # this logs once per period rather than every five seconds.
    @spec wait(Machine.t(), String.t()) :: {:keep_state, Machine.t(), list()}
    defp wait(data, why) do
      Logger.warning("fleet machine #{data.id}: #{why}; keeping it and waiting")

      {:keep_state, Machine.with_deadline(data, data.cfg.nodedown_grace),
       [{:state_timeout, poll(), :poll}]}
    end

    @spec poll() :: non_neg_integer()
    defp poll, do: Machine.recover_poll()

    # The monitor was consumed by the nodedown, so re-arm it. A machine that
    # rebooted comes back uncordoned (cordon state is not persisted), so anything
    # that was being held back has to be held back again before we resume.
    @spec recover(Machine.t()) ::
            {:next_state, Machine.phase(), Machine.t()}
            | {:next_state, Machine.phase(), Machine.t(), list()}
    defp recover(%{resume: :draining} = data) do
      :ok = Machine.watch(data.node)
      Machine.enter_draining(%{data | resume: nil})
    end

    defp recover(%{resume: :cordoned} = data) do
      :ok = Machine.watch(data.node)
      _ = Machine.set_cordon(data, true)
      Machine.enter_cordoned(%{data | resume: nil})
    end

    defp recover(data), do: Machine.enter_ready(data)
  end

  defmodule Cordoned do
    @moduledoc """
    Held back from placement, keeping its VMs. Stable until drained or reclaimed
    — but not idle: the poll re-asserts the cordon, because the flag lives in the
    far side's `Hyper.Node.Cordon` and does not survive a reboot of that node or
    a restart of that process. Nothing else would notice it had been cleared: the
    node stays in distribution, so no `:nodedown` fires, and the scheduler would
    quietly start filling a machine this controller believes is being emptied.
    """

    alias Hyper.Cluster.Fleet.Machine

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:state_timeout, :poll, data) do
      _ = Machine.set_cordon(data, true)
      {:keep_state_and_data, [{:state_timeout, Machine.cordon_poll(), :poll}]}
    end

    # Re-asserted rather than answered from memory: the node may have rebooted
    # since, and a rebooted node comes back schedulable.
    def handle({:call, from}, :cordon, data) do
      _ = Machine.set_cordon(data, true)
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end

    def handle({:call, from}, :drain, data) do
      Machine.enter_draining(data, [{:reply, from, :ok}])
    end

    def handle({:call, from}, :uncordon, data) do
      _ = Machine.set_cordon(data, false)
      {:next_state, :ready, %{data | deadline: nil}, [{:reply, from, :ok}]}
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :cordoned)
  end

  defmodule Draining do
    @moduledoc "Cordoned and counting VMs down to zero, then `:terminating`."

    require Logger

    alias Hyper.Cluster.Fleet.Machine

    # The count is read from the routing registry, which has no liveness filter
    # and lags a departing VM - so it may also go back *up* (the cordon reaches
    # other schedulers only on the next budget heartbeat). Neither matters: this
    # is a poll for zero, not an assumption of monotone decrease. The cordon is
    # re-asserted first, every time: a drain that stopped holding placements back
    # is a drain that never finishes.
    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:state_timeout, :poll, data) do
      _ = Machine.set_cordon(data, true)

      case Machine.vms_on(data.node) do
        0 ->
          {:next_state, :terminating, %{data | failures: 0, deadline: nil},
           [{:state_timeout, 0, :destroy}]}

        count ->
          hold_or_wait(data, count)
      end
    end

    def handle({:call, from}, :uncordon, data) do
      _ = Machine.set_cordon(data, false)
      Logger.info("fleet machine #{data.id}: drain cancelled, machine reclaimed")
      {:next_state, :ready, %{data | deadline: nil}, [{:reply, from, :ok}]}
    end

    def handle({:call, from}, event, _data) when event in [:cordon, :drain] do
      {:keep_state_and_data, [{:reply, from, :ok}]}
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :draining)

    # The deadline bounds the *drain*, not the VMs: a machine that still has work
    # on it is never destroyed to meet a schedule. Falling back to `:cordoned`
    # keeps it unschedulable and frees the Governor to drain a different machine
    # instead of waiting on this one forever.
    @spec hold_or_wait(Machine.t(), pos_integer()) ::
            {:next_state, Machine.phase(), Machine.t(), list()} | {:keep_state_and_data, list()}
    defp hold_or_wait(data, count) do
      if Machine.lapsed?(data) do
        Logger.warning(
          "fleet machine #{data.id}: #{count} VM(s) still on #{data.node} at the drain " <>
            "deadline; holding it cordoned instead of destroying them"
        )

        Machine.enter_cordoned(data)
      else
        {:keep_state_and_data, [{:state_timeout, Machine.drain_poll(), :poll}]}
      end
    end
  end

  defmodule Terminating do
    @moduledoc """
    Destroy the machine at the provider (idempotent), then stop.

    This is the only place in Fleet that deletes anything, so it is also where
    the rule that protects running work lives: a machine still hosting VMs is
    never destroyed, whichever of the four paths into this phase was taken. That
    machine is drained instead, and comes back here once it is empty.
    """

    require Logger

    alias Hyper.Cluster.Fleet.Machine

    @doc false
    @spec handle(:gen_statem.event_type(), term(), Machine.t()) ::
            :gen_statem.event_handler_result(Machine.phase())
    def handle(:state_timeout, :destroy, data) do
      cond do
        is_nil(data.provider_id) -> {:stop, {:shutdown, :never_created}, data}
        not Machine.supports?(data, :destroy) -> released(data)
        true -> spare_or_destroy(data)
      end
    end

    def handle(type, content, data), do: Machine.unhandled(type, content, data, :terminating)

    # The guard is here rather than on each path into the phase because the paths
    # disagree about *why* the machine should stop existing and agree about this:
    # none of them is a reason to kill someone's VM. A machine with work on it is
    # drained, which is the same answer scale-in gives and ends up back here.
    @spec spare_or_destroy(Machine.t()) ::
            {:stop, term(), Machine.t()}
            | {:keep_state, Machine.t(), list()}
            | {:next_state, Machine.phase(), Machine.t(), list()}
    defp spare_or_destroy(data) do
      case Machine.vms_on(data.node) do
        0 -> destroy(data)
        count -> spare(data, count)
      end
    end

    @spec spare(Machine.t(), pos_integer()) ::
            {:next_state, Machine.phase(), Machine.t(), list()}
    defp spare(data, count) do
      Logger.warning(
        "fleet machine #{data.id}: not destroying #{data.provider_id} with #{count} VM(s) " <>
          "still on #{data.node}; draining it first"
      )

      Machine.enter_draining(%{data | failures: 0})
    end

    # A provider that does not implement destroy still gets the whole lifecycle
    # above this point; it simply keeps its machines. Stopping (rather than
    # looping on `{:error, :not_supported}`) leaves a cordoned, drained machine
    # for the operator to retire the way they created it.
    @spec released(Machine.t()) :: {:stop, term(), Machine.t()}
    defp released(data) do
      Logger.info(
        "fleet machine #{data.id}: provider cannot destroy machines; " <>
          "leaving #{data.provider_id} in place, cordoned"
      )

      {:stop, {:shutdown, :destroy_unsupported}, data}
    end

    @spec destroy(Machine.t()) ::
            {:stop, term(), Machine.t()} | {:keep_state, Machine.t(), list()}
    defp destroy(data) do
      case data.cfg.provider.destroy(data.provider_state, data.provider_id) do
        :ok ->
          Logger.info("fleet machine #{data.id}: destroyed #{data.provider_id}")
          {:stop, {:shutdown, :destroyed}, data}

        {:error, reason} ->
          keep_trying(data, reason)
      end
    end

    # Bounded, because a machine we cannot delete is a bill that keeps arriving
    # and the retry is better owned by the Governor: it re-lists, re-adopts what
    # is still there, and this controller runs again from a clean slate.
    @spec keep_trying(Machine.t(), term()) ::
            {:stop, term(), Machine.t()} | {:keep_state, Machine.t(), list()}
    defp keep_trying(data, reason) do
      data = %{data | failures: data.failures + 1}

      if data.failures >= Machine.destroy_attempts() do
        Logger.error(
          "fleet machine #{data.id}: could not destroy #{data.provider_id} after " <>
            "#{data.failures} attempts (#{inspect(reason)}); leaving it for the governor"
        )

        {:stop, {:shutdown, {:destroy_failed, reason}}, data}
      else
        Logger.warning(
          "fleet machine #{data.id}: destroy of #{data.provider_id} failed " <>
            "(#{inspect(reason)}); retrying"
        )

        {:keep_state, data, [{:state_timeout, Machine.backoff(data.failures), :destroy}]}
      end
    end
  end
end
