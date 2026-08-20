defmodule Hyper.Provider do
  @moduledoc """
  Behaviour for pluggable node providers.

  A provider knows how to acquire, release, and enumerate the bare-metal (or
  cloud) machines Hyper schedules microVMs onto. Each callback receives an
  opaque provider `t:cfg/0` map (credentials, region, plan, ...) so a single
  provider module can serve many differently-configured pools without global
  state.

  Implementations are expected to be side-effecting network clients; they must
  translate their vendor API into the neutral `t:node_ref/0` shape and surface
  failures as `{:error, term()}` rather than raising, so the caller can decide
  on retry/backoff policy.
  """

  @typedoc "Opaque, provider-specific configuration (credentials, region, plan, ...)."
  @type cfg :: map()

  @typedoc """
  A provider-neutral handle to one machine.

    * `:ref` — the provider's stable identifier, passed back to `c:destroy_node/2`.
    * `:hostname` — the machine's hostname.
    * `:ip` — public IPv4 once assigned, `nil` while still provisioning.
    * `:status` — the provider's lifecycle status string, verbatim.
  """
  @type node_ref :: %{
          ref: String.t(),
          hostname: String.t(),
          ip: String.t() | nil,
          status: String.t()
        }

  @doc """
  Provision a new node, injecting `user_data` (a cloud-init script) to run on
  first boot, and block until it is reachable. Returns its `t:node_ref/0`.
  """
  @callback create_node(cfg(), user_data :: String.t()) ::
              {:ok, node_ref()} | {:error, term()}

  @doc "Tear down the node identified by `ref`."
  @callback destroy_node(cfg(), ref :: String.t()) :: :ok | {:error, term()}

  @doc "Enumerate the nodes this provider currently owns for the configured pool."
  @callback list_nodes(cfg()) :: {:ok, [node_ref()]} | {:error, term()}
end
