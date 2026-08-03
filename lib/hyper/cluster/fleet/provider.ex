defmodule Hyper.Cluster.Fleet.Provider do
  @moduledoc """
  The only provider-specific code in Fleet: how to *see*, *make* and *unmake*
  machines at one infrastructure vendor.

  Everything above this boundary — `Hyper.Cluster.Fleet.Machine`'s lifecycle,
  `Hyper.Cluster.Fleet.Governor`'s regulation, `Hyper.Cluster.Fleet.Policy`'s
  arithmetic — is vendor-agnostic and speaks only in `t:Hyper.Cluster.Fleet.Machine.Info.t/0`
  and the canonical statuses. A provider is configured once, in `config.exs`,
  alongside its credentials (see `Hyper.Cfg.Fleet`).

  ## What an implementation must guarantee

  ### `list/1` returns only machines carrying our tags

  This is the safety-critical property of the whole feature and it is enforced
  *nowhere else*. `Hyper.Cluster.Fleet.Governor` adopts, cordons, drains and
  ultimately destroys whatever `list/1` reports; no layer above re-checks
  ownership. An untagged machine — someone else's database server in the same
  account — must therefore be invisible to `list/1`, because a machine Fleet
  cannot see is a machine Fleet can never destroy. Filter by tag inside the
  provider, on the vendor's own query if it supports one, and drop anything that
  does not match on the way out.

  ### Statuses are canonical

  Vendor strings (`"provisioning"`, `"halted"`, `"failed-install"`) are mapped to
  `t:status/0` inside the provider and never escape it. When in doubt, map to the
  status whose *action* is right: a machine that will never become usable is
  `:error` (replace it), one that has vanished is `:gone` (forget it), one that
  might still come good is `:pending` (keep waiting).

  ### `destroy/2` is idempotent

  Destroying an id that is already gone — or was never known — is `:ok`, not an
  error. The controller calls `destroy/2` from `:terminating`, a state it may
  re-enter after a crash or a controller migration, so a "not found" mapped to
  `{:error, _}` would strand a machine that is in fact already deleted. Reserve
  `{:error, _}` for "I could not carry out the request" (a transport failure, a
  refusal), which the controller retries.

  ### `create/2` is slow and may fail

  Minutes, not milliseconds — the caller drives it with a deadline and a backoff,
  so blocking is expected and failing is normal. `create/2` must apply the `tags`
  it is given, atomically with creation if the vendor allows it: a machine that
  exists but is untagged is invisible to `list/1` and therefore an orphan Hyper
  pays for forever. If tagging can only happen after creation and that second
  step fails, destroy what you just made and return an error.

  ### There is deliberately no health or readiness callback

  Do not add one. **Cluster membership is the readiness probe**: a machine is
  ready exactly when its node appears in `Hyper.Cluster.Budget.all_states/0`,
  because that is the only definition of ready that matters — it means the BEAM
  booted, Hyper started, and the scheduler can place work there. A provider's
  own health endpoint can say "running" about a machine whose Hyper never
  started, and Fleet would believe it.

  ### There is deliberately no size, plan or capacity parameter

  Notice that no callback takes a machine size. Hyper never chooses a shape at
  runtime: the plan / instance type / region is deployment configuration, set in
  `config.exs` next to the credentials and passed to `init/1`, with "the largest
  the provider offers" as the documented default. The fleet is therefore
  uniform, which is what lets `Hyper.Cluster.Fleet.Policy` grow it one machine at
  a time and re-measure instead of solving a packing problem. A provider that
  needs a second shape is a second provider configuration.

  ## Capabilities

  `capabilities/1` declares which mutations the provider actually implements.
  A provider that only implements `list/1` (`capabilities/1 == []`) still gives a
  real fleet: Hyper adopts, monitors, cordons and drains those machines, it just
  never creates or destroys them. That is exactly what
  `Hyper.Cluster.Fleet.Provider.Static` is, and it is the default — pre-existing
  metal is a first-class deployment, not a degraded one.
  """

  alias Hyper.Cluster.Fleet.Machine.Info

  @typedoc """
  Provider-private state, threaded through every callback.

  Whatever `init/1` returns: an HTTP client, a credential, a decoded config
  struct. It is opaque to Fleet, and it must be reconstructible from the
  configured options alone — a controller that migrates to another node re-runs
  `init/1` there rather than carrying this term across.
  """
  @type state :: term()

  @typedoc "A mutation the provider implements."
  @type capability :: :create | :destroy

  @typedoc "Canonical machine lifecycle; see `t:Hyper.Cluster.Fleet.Machine.Info.status/0`."
  @type status :: Info.status()

  @typedoc "Provider-side tags; see `t:Hyper.Cluster.Fleet.Machine.Info.tags/0`."
  @type tags :: Info.tags()

  @doc """
  Build the provider's private state from its configured options.

  `opts` is `Hyper.Cfg.Fleet`'s `provider_opts` verbatim: credentials, region,
  plan — everything vendor-specific. Called on every node that ends up running a
  controller for this provider, so it must be cheap and side-effect-free enough
  to run repeatedly (open a client, do not create resources).
  """
  @callback init(opts :: keyword()) :: {:ok, state()} | {:error, term()}

  @doc """
  Which mutations this provider implements.

  `[]` means observe-only: the Governor will refuse to regulate the fleet's size
  and Hyper limits itself to monitoring, cordoning and draining.
  """
  @callback capabilities(state()) :: [capability()]

  @doc """
  Every machine at the provider that carries our tags — and nothing else.

  Doubles as the membership source for `Hyper.Cluster.Fleet.Strategy` and as
  orphan detection for the Governor, which is why an untagged machine must never
  appear here. `{:error, _}` is a transient failure: the caller retries on its
  next tick rather than concluding the fleet is empty.
  """
  @callback list(state()) :: {:ok, [Info.t()]} | {:error, term()}

  @doc """
  Create one machine of the configured shape, carrying `tags`.

  May block for minutes and may fail; both are normal. The returned `Info` is
  usually `:pending` — the caller waits for the node to join the cluster, it
  does not ask the provider whether the machine is ready.
  """
  @callback create(state(), tags()) :: {:ok, Info.t()} | {:error, term()}

  @doc """
  Destroy the machine with this provider id.

  Idempotent: an id that is already gone, or was never known, is `:ok`.
  """
  @callback destroy(state(), id :: Info.id()) :: :ok | {:error, term()}

  @doc """
  Whether `provider` declares `capability` for this `state`.

  The single expression of the "never mutate what the provider does not
  implement" rule, so callers ask this instead of matching on
  `capabilities/1` themselves.
  """
  @spec supports?(module(), state(), capability()) :: boolean()
  def supports?(provider, state, capability) do
    capability in provider.capabilities(state)
  end
end
