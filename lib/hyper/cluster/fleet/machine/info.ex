defmodule Hyper.Cluster.Fleet.Machine.Info do
  @moduledoc """
  A provider's observation of one machine — the only value that crosses the
  `Hyper.Cluster.Fleet.Provider` boundary.

  This is deliberately *not* `Hyper.Cluster.Fleet.Machine`: the `Machine`
  `:gen_statem` holds live controller data (deadlines, failure counters, the
  provider's private state), while an `Info` is a flat, serialisable snapshot
  that a provider can produce from a single API response and that survives being
  stored in a Horde child spec.

  The fields are the intersection every provider can honestly answer:

    * `id` — the provider's own durable identifier for the machine. It is the
      only stable identity Hyper has (a node name may not exist yet, an IP may
      change), so it keys the controller's `{:machine, id}` registration.
    * `node` — the BEAM node name the machine will join as, or `nil` while it is
      not yet known. A provider that can derive the node name from its naming
      convention should fill it in even before the machine boots; a provider
      that cannot leaves it `nil` and the controller learns it at join time.
    * `status` — the canonical lifecycle atom (see `t:status/0`). Vendor status
      strings are mapped here and never escape the provider.
    * `tags` — the tags the machine actually carries at the provider. This is
      what makes the machine ours; see the tag-scoping rule in
      `Hyper.Cluster.Fleet.Provider`.
    * `created_at` — when the provider says the machine came into existence, or
      `nil` if the provider does not report it. Advisory only: nothing in Fleet
      makes a destroy decision from it.

  `status` is defined here rather than on the behaviour so that the behaviour can
  depend on this struct and not the other way round; `Hyper.Cluster.Fleet.Provider`
  re-exports it as `t:Hyper.Cluster.Fleet.Provider.status/0`.
  """

  @typedoc "A provider's durable identifier for a machine."
  @type id :: String.t()

  @typedoc """
  Canonical machine lifecycle, mapped from whatever the vendor calls it:

    * `:pending` — the provider has accepted the machine but it is not yet
      usable (queued, installing, booting).
    * `:active` — the provider considers the machine running. This says nothing
      about whether it has joined the BEAM cluster; readiness is observed by
      Hyper, not asked of the provider.
    * `:gone` — the machine no longer exists at the provider (deleted, or never
      existed). A machine that has disappeared is `:gone`, not `:error`.
    * `:error` — the machine exists but the provider reports it as failed. It
      will not become usable on its own and should be replaced.
  """
  @type status :: :pending | :active | :gone | :error

  @typedoc """
  Provider-side tags. String-keyed and string-valued because every provider tag
  API is, and because a tag Hyper writes on create must compare equal to the tag
  it reads back on list.
  """
  @type tags :: %{optional(String.t()) => String.t()}

  @type t :: %__MODULE__{
          id: id(),
          node: node() | nil,
          status: status(),
          tags: tags(),
          created_at: DateTime.t() | nil
        }

  @enforce_keys [:id, :status]
  defstruct [:id, :status, :node, :created_at, tags: %{}]
end
