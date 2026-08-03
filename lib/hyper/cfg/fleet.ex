defmodule Hyper.Cfg.Fleet do
  @moduledoc """
  Machine-level autoscaling configuration: *who* supplies machines, and *how
  many* Hyper is allowed to keep.

  The two halves read from different layers on purpose.

    * **Provider and its options** — `config.exs`-only
      (`config :hyper, Hyper.Cfg.Fleet, provider: ..., provider_opts: [...]`),
      for the same reason `Hyper.Cfg.Cluster` is: a provider is a module
      reference, and `provider_opts` carries the API credentials and the machine
      shape (plan, region, image), which belong in the operator's secrets layer
      and must never be readable from the helper-shared TOML.
    * **Regulation knobs** — `config.exs`, then the `[fleet]` table of
      `/etc/hyper/config.toml`, then the built-in default. These are operational
      tuning an operator may want to change without touching secrets. Durations
      are `Unit.Time` — Elixir terms in `config.exs`, strings (`"120s"`, `"30m"`)
      in TOML.

  The defaults are deliberately inert: `Hyper.Cluster.Fleet.Provider.Static`
  declares no machines and implements no mutation, so an install that never
  configures a fleet regulates nothing. Autoscaling is opted into by naming a
  provider that can create.

  Knob semantics:

    * `min_nodes` / `max_nodes` — the size band the fleet is kept within.
      `max_nodes: nil` means unbounded, which is only sane behind a provider
      quota; set it. `min_nodes` is also the cold-start target.
    * `target_headroom` — how many *more* machines' worth of spare capacity to
      keep, measured by `Hyper.Cluster.Fleet.Policy` as how many additional
      `reference_type` instances the cluster could still place. It is a count of
      VMs, not a percentage, because that is the unit placement actually fails in.
    * `reference_type` — the `Hyper.Vm.Instance` type headroom is counted in.
      Validated here against `Hyper.Vm.Instance.types/0`, so a typo fails at load
      instead of raising inside the Governor's first tick.
    * `cooldown` — minimum time between two size changes, so the fleet reacts to
      a machine having joined rather than to the same shortage twice.
    * `provision_deadline` — how long `Provider.create/2` and the subsequent boot
      may take before the machine is written off and replaced.
    * `nodedown_grace` — how long a joined machine may stay unreachable before it
      is treated as lost. A machine that never returns is replaced, not mourned.
    * `drain_deadline` — how long to wait for a cordoned machine's VMs to end on
      their own. VMs cannot migrate, so waiting is the only scale-in path, and
      this bound is what stops a single long-lived VM from pinning a machine
      forever.

  Deliberately **not** cached in `:persistent_term` the way `Hyper.Cfg.Budget`
  is. Nothing reads this configuration on a hot path — every consumer threads the
  loaded struct through — while `:persistent_term.put/2` over an existing term
  forces a scan of every process heap. `load/0` is called from the Governor's
  first tick and from the interactive `Hyper.Cluster.Fleet` levers, so caching it
  would trade a global pause for a file read nobody was waiting on.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  alias Hyper.Cluster.Fleet.Provider
  alias Hyper.Vm.Instance

  @type t :: %__MODULE__{
          provider: module(),
          provider_opts: keyword(),
          min_nodes: non_neg_integer(),
          max_nodes: pos_integer() | nil,
          target_headroom: non_neg_integer(),
          reference_type: Instance.t(),
          cooldown: Unit.Time.t(),
          provision_deadline: Unit.Time.t(),
          nodedown_grace: Unit.Time.t(),
          drain_deadline: Unit.Time.t()
        }
  defstruct [
    :provider,
    :provider_opts,
    :min_nodes,
    :max_nodes,
    :target_headroom,
    :reference_type,
    :cooldown,
    :provision_deadline,
    :nodedown_grace,
    :drain_deadline
  ]

  @default_provider Provider.Static
  @default_provider_opts []
  @default_min_nodes 0
  @default_max_nodes nil
  @default_target_headroom 1
  @default_reference_type :base
  @default_cooldown Unit.Time.s(120)
  @default_provision_deadline Unit.Time.s(600)
  @default_nodedown_grace Unit.Time.s(300)
  @default_drain_deadline Unit.Time.s(1800)

  @spec load :: {:ok, t()} | {:error, term()}
  def load do
    with {:ok, provider} <- provider(),
         {:ok, provider_opts} <- provider_opts(),
         {:ok, min_nodes} <- count(:min_nodes, "fleet.min_nodes", @default_min_nodes),
         {:ok, max_nodes} <- optional_count(:max_nodes, "fleet.max_nodes", @default_max_nodes),
         :ok <- band(min_nodes, max_nodes),
         {:ok, headroom} <-
           count(:target_headroom, "fleet.target_headroom", @default_target_headroom),
         {:ok, reference_type} <- reference_type(),
         {:ok, cooldown} <- duration(:cooldown, "fleet.cooldown", @default_cooldown),
         {:ok, provision_deadline} <-
           duration(:provision_deadline, "fleet.provision_deadline", @default_provision_deadline),
         {:ok, nodedown_grace} <-
           duration(:nodedown_grace, "fleet.nodedown_grace", @default_nodedown_grace),
         {:ok, drain_deadline} <-
           duration(:drain_deadline, "fleet.drain_deadline", @default_drain_deadline) do
      config = %__MODULE__{
        provider: provider,
        provider_opts: provider_opts,
        min_nodes: min_nodes,
        max_nodes: max_nodes,
        target_headroom: headroom,
        reference_type: reference_type,
        cooldown: cooldown,
        provision_deadline: provision_deadline,
        nodedown_grace: nodedown_grace,
        drain_deadline: drain_deadline
      }

      {:ok, config}
    end
  end

  @spec provider :: {:ok, module()} | {:error, term()}
  defp provider do
    case deployment(:provider, @default_provider) do
      mod when is_atom(mod) and not is_nil(mod) -> {:ok, mod}
      other -> {:error, {:bad_value, :provider, other}}
    end
  end

  @spec provider_opts :: {:ok, keyword()} | {:error, term()}
  defp provider_opts do
    case deployment(:provider_opts, @default_provider_opts) do
      opts when is_list(opts) -> keyword(opts)
      other -> {:error, {:bad_value, :provider_opts, other}}
    end
  end

  @spec keyword(list()) :: {:ok, keyword()} | {:error, term()}
  defp keyword(opts) do
    if Keyword.keyword?(opts), do: {:ok, opts}, else: {:error, {:bad_value, :provider_opts, opts}}
  end

  @spec count(atom(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  defp count(key, toml, default) do
    case knob(key, toml, default) do
      n when is_integer(n) and n >= 0 -> {:ok, n}
      other -> {:error, {:bad_value, key, other}}
    end
  end

  # `max_nodes` is nilable, and an explicit `nil` is meaningful rather than
  # missing: it is how an operator says "no ceiling" in config.exs.
  @spec optional_count(atom(), String.t(), pos_integer() | nil) ::
          {:ok, pos_integer() | nil} | {:error, term()}
  defp optional_count(key, toml, default) do
    case knob(key, toml, default) do
      nil -> {:ok, nil}
      n when is_integer(n) and n > 0 -> {:ok, n}
      other -> {:error, {:bad_value, key, other}}
    end
  end

  @spec band(non_neg_integer(), pos_integer() | nil) :: :ok | {:error, term()}
  defp band(_min, nil), do: :ok
  defp band(min, max) when max >= min, do: :ok
  defp band(min, max), do: {:error, {:bad_range, :max_nodes, {min, max}}}

  @spec reference_type :: {:ok, Instance.t()} | {:error, term()}
  defp reference_type do
    value = knob(:reference_type, "fleet.reference_type", @default_reference_type)

    case Enum.find(Instance.types(), &named?(&1, value)) do
      nil -> {:error, {:bad_value, :reference_type, value}}
      type -> {:ok, type}
    end
  end

  # TOML has no atoms, so an instance type arrives as a string from that layer;
  # matching by name avoids ever creating an atom from configuration.
  @spec named?(Instance.t(), term()) :: boolean()
  defp named?(type, value) when is_atom(value), do: type == value
  defp named?(type, value) when is_binary(value), do: Atom.to_string(type) == value
  defp named?(_type, _value), do: false

  @spec duration(atom(), String.t(), Unit.Time.t()) :: {:ok, Unit.Time.t()} | {:error, term()}
  defp duration(key, toml, default) do
    case knob(key, toml, default) do
      %Unit.Time{} = t -> {:ok, t}
      s when is_binary(s) -> parse_duration(key, s)
      other -> {:error, {:bad_value, key, other}}
    end
  end

  @spec parse_duration(atom(), String.t()) :: {:ok, Unit.Time.t()} | {:error, term()}
  defp parse_duration(key, s) do
    case Unit.Time.parse(s) do
      {:ok, t} -> {:ok, t}
      {:error, _} -> {:error, {:bad_value, key, s}}
    end
  end

  @spec knob(atom(), String.t(), term()) :: term()
  defp knob(key, toml, default) do
    get_cfg(runtime: {__MODULE__, key}, toml: toml, default: default)
  end

  # Provider identity and credentials are config.exs-only: they name modules and
  # carry secrets, neither of which belongs in the helper-shared TOML.
  @spec deployment(atom(), term()) :: term()
  defp deployment(key, default) do
    get_cfg(runtime: {__MODULE__, key}, default: default)
  end
end
