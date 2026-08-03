defmodule Hyper.Cfg.Node do
  @moduledoc """
  What this machine is *for*: `:host` (the default) runs microVMs, `:control`
  never does.

  A control node still forms the cluster, still serves the gRPC API, still reads
  and writes the image database, and still runs the fleet's `Governor` — it
  simply does not start `Hyper.Node`, so it has no VM supervisor, no budget, and
  no `Hyper.Node.Budget.Advertiser`. It exists because a machine that *provisions*
  hosts need not be able to *be* one: an operator laptop, a CI runner, or a small
  API box has no KVM, no firecracker, and no setuid helper, and demanding them
  makes the orchestrator unrunnable exactly where you want to run it.

  Placement needs no knowledge of this. A node earns candidacy by publishing a
  `Hyper.Node.Budget.NodeState` into `Hyper.Cluster.Budget`, and a control node
  publishes none, so `Hyper.Cluster.Scheduler` never sees it. Absence is the
  whole mechanism; there is no "is this a host?" check on the placement path.

  Distinct from `Hyper.Node.Cordon`, which is the *runtime* refusal of a machine
  that is perfectly capable of hosting and is being emptied. This is a static
  statement about what the machine can do at all, read once at boot, and it is
  not something the fleet can change.

  Read from `config.exs` (`config :hyper, Hyper.Cfg.Node, role: :control`), then
  the `[node]` table in `config.toml` (`role = "control"`), then the default
  `:host` — so every existing deployment keeps its behaviour without touching a
  config file.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @typedoc "Whether this machine may run microVMs."
  @type role :: :host | :control

  @default_role :host

  @doc "This machine's role. Raises on an unrecognised value rather than guessing."
  @spec role() :: role()
  def role do
    case get_cfg(runtime: {__MODULE__, :role}, toml: "node.role", default: @default_role) do
      role when role in [:host, :control] ->
        role

      "host" ->
        :host

      "control" ->
        :control

      other ->
        raise ArgumentError, "node.role must be \"host\" or \"control\", got: #{inspect(other)}"
    end
  end

  @doc "Whether this machine runs microVMs."
  @spec host?() :: boolean()
  def host?, do: role() == :host

  @doc "Whether this machine orchestrates without hosting."
  @spec control?() :: boolean()
  def control?, do: role() == :control
end
