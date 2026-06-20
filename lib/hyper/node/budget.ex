defmodule Hyper.Node.Budget do
  @moduledoc """
  Per-node resource budgets and the cluster-wide scheduling query built on them.

  `architecture.md` defines two budget categories:

    * **alpha (hard)** - `mem` and `disk`. The resources a VM *requires*. A node must
      keep at least the sum of its VMs' alpha reservations free; exceeding alpha makes VMs
      spuriously crash. This module + `Hyper.Node.Budget.Hard` implement alpha.

    * **beta (soft)** - `vcpus`, `disk_bw`, `net_bw`. Overloadable: exceeding beta
      degrades speed, not service. beta needs real-time load sampling and lives in a
      future `Hyper.Node.Budget.Soft`. Not implemented here.

  ## Why no CRDT / distributed store

  alpha is a hard invariant, so the authoritative check is a node-local atomic
  reserve in `Hyper.Node.Budget.Hard` - the node that owns the VMs owns the
  ledger. Cluster-wide reads for scheduling (`havail/2`) are plain
  `:erpc.multicall` over Distributed Erlang (the cluster is formed by
  `libcluster`); each node answers from its own ledger, so there is nothing to
  replicate and nothing eventually-consistent to over-commit against. We
  deliberately do **not** push alpha through Horde/`DeltaCrdt`.
  """

  use Unit.Operators

  alias Hyper.Node.Budget.Hard
  alias Hyper.Vm.Instance.Spec
  alias Unit.Information

  defmodule Alpha do
    @moduledoc "The hard-budget resource vector: required memory and disk."

    @type t :: %__MODULE__{
            mem: Unit.Information.t(),
            disk: Unit.Information.t()
          }

    @enforce_keys [:mem, :disk]
    defstruct [:mem, :disk]
  end

  @doc "The alpha (hard) resource vector required to run a VM of `spec`."
  @spec alpha(Spec.t()) :: Alpha.t()
  def alpha(%Spec{mem: mem, disk: disk}), do: %Alpha{mem: mem, disk: disk}

  @doc "The empty budget - additive identity for `add/2`."
  @spec zero() :: Alpha.t()
  def zero, do: %Alpha{mem: Information.zero(), disk: Information.zero()}

  @doc "Dimension-wise sum of two alpha vectors."
  @spec add(Alpha.t(), Alpha.t()) :: Alpha.t()
  def add(%Alpha{} = a, %Alpha{} = b) do
    %Alpha{mem: a.mem + b.mem, disk: a.disk + b.disk}
  end

  @doc "Dimension-wise difference `a - b`, clamped at zero per dimension."
  @spec sub(Alpha.t(), Alpha.t()) :: Alpha.t()
  def sub(%Alpha{} = a, %Alpha{} = b) do
    %Alpha{mem: a.mem - b.mem, disk: a.disk - b.disk}
  end

  @doc """
  Whether `avail` can satisfy `need`: at least `need` free in **every** dimension.
  """
  @spec fits?(Alpha.t(), Alpha.t()) :: boolean()
  def fits?(%Alpha{} = avail, %Alpha{} = need) do
    need.mem <= avail.mem and need.disk <= avail.disk
  end

  @default_timeout_ms 5_000

  @doc """
  The set of nodes whose **hard budget** can currently hold a VM of `spec` -
  `architecture.md`'s `havail(N, VM)`.

  Polls each node's `Hyper.Node.Budget.Hard` ledger via `:erpc.multicall` and
  keeps those with at least `alpha(spec)` free. Nodes that error or time out are
  treated as unavailable and dropped.

  Options: `:nodes` (default `[node() | Node.list()]`), `:server` (the `Hard`
  name to query, default `Hyper.Node.Budget.Hard`), `:timeout` (ms, default
  #{@default_timeout_ms}).
  """
  @spec havail(Spec.t(), keyword()) :: [node()]
  def havail(%Spec{} = spec, opts \\ []) do
    nodes = Keyword.get(opts, :nodes, [node() | Node.list()])
    server = Keyword.get(opts, :server, Hard)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    need = alpha(spec)

    nodes
    |> :erpc.multicall(Hard, :avail, [server], timeout)
    |> Enum.zip(nodes)
    |> Enum.filter(fn
      {{:ok, %Alpha{} = avail}, _node} -> fits?(avail, need)
      {_other, _node} -> false
    end)
    |> Enum.map(fn {_result, node} -> node end)
  end
end
