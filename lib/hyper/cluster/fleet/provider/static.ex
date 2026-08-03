defmodule Hyper.Cluster.Fleet.Provider.Static do
  @moduledoc """
  The default provider: a fixed, hand-declared fleet.

  There is no API and no vendor here — the machines are whatever the operator
  listed in `config.exs`:

      config :hyper, Hyper.Cfg.Fleet,
        provider: Hyper.Cluster.Fleet.Provider.Static,
        provider_opts: [nodes: [:"hyper@10.0.0.1", :"hyper@10.0.0.2"]]

  This is what makes Fleet safe to switch on everywhere. A fixed fleet is still a
  fleet: Hyper adopts a controller per machine, watches it join, cordons and
  drains it on request — every part of the feature except the two operations that
  cost money. `capabilities/1` is `[]`, so `Hyper.Cluster.Fleet.Governor` refuses
  to regulate the fleet's size and no machine is ever created or destroyed
  behind the operator's back. Manual drain before a kernel upgrade works exactly
  as it does on an autoscaled fleet.

  It is also the test double for everything above the provider boundary: it is
  pure, its `list/1` is whatever you configured, and its refusals are the same
  refusals a real provider gives for an unimplemented capability.

  Machines are declared by node name because that *is* their durable identity
  here — a static machine has no provider-side id to borrow, and the node name is
  the one thing both the operator and the cluster already agree on. `list/1`
  reports every configured machine as `:active` regardless of whether the node is
  currently reachable: existence is all this provider can honestly claim, and
  readiness is decided by cluster membership, not by the provider.
  """

  @behaviour Hyper.Cluster.Fleet.Provider

  alias Hyper.Cluster.Fleet.Machine.Info

  @typedoc "The declared fleet: its node names and the tags they are reported with."
  @type t :: %__MODULE__{nodes: [node()], tags: Info.tags()}

  @enforce_keys [:nodes, :tags]
  defstruct [:nodes, :tags]

  @doc """
  Options are `nodes:` (node names, as atoms or strings) and `tags:` (a
  string-keyed map reported with every machine, `%{}` by default).

  An unconfigured `nodes:` is an empty fleet, not an error — that is the correct
  reading of "no machines declared", and it keeps a default install bootable.
  """
  @impl Hyper.Cluster.Fleet.Provider
  @spec init(keyword()) :: {:ok, t()} | {:error, term()}
  def init(opts) do
    with {:ok, nodes} <- nodes(Keyword.get(opts, :nodes, [])),
         {:ok, tags} <- tags(Keyword.get(opts, :tags, %{})) do
      {:ok, %__MODULE__{nodes: nodes, tags: tags}}
    end
  end

  @doc "None. A static fleet is observed, never mutated."
  @impl Hyper.Cluster.Fleet.Provider
  @spec capabilities(t()) :: []
  def capabilities(%__MODULE__{}), do: []

  @doc "The configured machines, all `:active` and all carrying the configured tags."
  @impl Hyper.Cluster.Fleet.Provider
  @spec list(t()) :: {:ok, [Info.t()]}
  def list(%__MODULE__{} = state) do
    {:ok, Enum.map(state.nodes, &info(&1, state.tags))}
  end

  @doc """
  Always `{:error, :not_supported}`, for every input, in agreement with
  `capabilities/1`.
  """
  @impl Hyper.Cluster.Fleet.Provider
  @spec create(t(), Info.tags()) :: {:error, :not_supported}
  def create(%__MODULE__{}, _tags), do: {:error, :not_supported}

  @doc """
  `:ok` for any id, having done nothing.

  A static machine is already in the state `destroy/2` promises — outside Hyper's
  control — so the idempotent contract is satisfied by a no-op rather than a
  refusal, and a controller that reaches `:terminating` for a static machine
  stops cleanly instead of retrying forever. The machine stays in `list/1` until
  the operator removes it from the configuration, which is the intended way to
  retire it.
  """
  @impl Hyper.Cluster.Fleet.Provider
  @spec destroy(t(), Info.id()) :: :ok
  def destroy(%__MODULE__{}, _id), do: :ok

  @spec info(node(), Info.tags()) :: Info.t()
  defp info(node, tags) do
    %Info{id: Atom.to_string(node), node: node, status: :active, tags: tags}
  end

  @spec nodes(term()) :: {:ok, [node()]} | {:error, term()}
  defp nodes(nodes) when is_list(nodes) do
    collected =
      Enum.reduce_while(nodes, {:ok, []}, fn entry, {:ok, acc} ->
        case node_name(entry) do
          {:ok, node} -> {:cont, {:ok, [node | acc]}}
          :error -> {:halt, {:error, {:bad_node, entry}}}
        end
      end)

    case collected do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, _} = err -> err
    end
  end

  defp nodes(other), do: {:error, {:bad_nodes, other}}

  # Strings are accepted so the same fleet can be declared from a deployment
  # template that has no way to write an Elixir atom.
  @spec node_name(term()) :: {:ok, node()} | :error
  defp node_name(node) when is_atom(node) and not is_nil(node), do: {:ok, node}
  defp node_name(node) when is_binary(node), do: {:ok, String.to_atom(node)}
  defp node_name(_other), do: :error

  @spec tags(term()) :: {:ok, Info.tags()} | {:error, term()}
  defp tags(tags) when is_map(tags) do
    if Enum.all?(tags, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      {:ok, tags}
    else
      {:error, {:bad_tags, tags}}
    end
  end

  defp tags(other), do: {:error, {:bad_tags, other}}
end
