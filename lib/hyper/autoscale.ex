defmodule Hyper.Autoscale.UserData do
  @moduledoc """
  Renders the cloud-init user-data (a bash script) handed to a freshly
  provisioned worker so it joins this Hyper cluster on boot. The body lives in
  `priv/deploy/latitude/user-data.sh.eex` and is rendered with the bootstrap
  params from `Hyper.Cfg.Autoscale.provider_cfg/0`. If that template is missing
  (e.g. a stripped release) a minimal script that only logs is used instead, so
  provisioning still returns a valid — if inert — script rather than crashing.
  """

  @template_segments ["priv", "deploy", "latitude", "user-data.sh.eex"]

  @doc "Render the worker bootstrap script for `cfg` (see `Hyper.Cfg.Autoscale.provider_cfg/0`)."
  @spec render(map()) :: String.t()
  def render(cfg) do
    assigns = %{
      release_url: cfg[:release_url],
      pg_url: cfg[:pg_url],
      cookie: cfg[:cookie],
      resolver: cfg[:resolver],
      hostname: hostname(cfg)
    }

    case template_file() do
      {:ok, path} -> EEx.eval_file(path, assigns: assigns)
      :error -> fallback(assigns)
    end
  end

  @spec hostname(map()) :: String.t()
  defp hostname(cfg) do
    prefix = cfg[:hostname_prefix] || "hyper-worker"
    "#{prefix}-#{:erlang.unique_integer([:positive])}"
  end

  @spec template_file() :: {:ok, Path.t()} | :error
  defp template_file do
    path = Application.app_dir(:hyper, @template_segments)
    if File.regular?(path), do: {:ok, path}, else: :error
  end

  @spec fallback(map()) :: String.t()
  defp fallback(assigns) do
    """
    #!/usr/bin/env bash
    echo "hyper: user-data template missing; cannot bootstrap #{assigns.hostname}" >&2
    """
  end
end

defmodule Hyper.Autoscale do
  @moduledoc """
  Reactive + periodic worker autoscaler. Started only on a `:client` node, it
  keeps the cluster's live worker count at or above `Hyper.Cfg.Autoscale.min_nodes/0`
  (never exceeding `max_nodes/0`) by provisioning nodes through the configured
  `Hyper.Provider` implementation.

  Two triggers drive it:

    * a periodic reconcile every `Hyper.Cfg.Autoscale.reconcile_interval_ms/0`,
      which tops the fleet back up to `min_nodes/0`, and
    * `request_capacity/0` — a reactive burst the scheduler casts when it returns
      `:no_capacity`, adding one node if there is still headroom under `max_nodes/0`.

  Everything is demo-grade and best-effort: failures are logged via `Logger` and
  never crash the process. Provisioning runs in an unlinked `Task` so a slow or
  failing provider API call cannot block the reconcile loop; in-flight
  provisions are counted in state so overlapping ticks never double-provision.
  If autoscaling is disabled or no API token is configured, it logs once and
  idles.
  """

  use GenServer
  require Logger

  alias Hyper.Autoscale.UserData
  alias Hyper.Cfg.Autoscale, as: Config
  alias Hyper.Img.Db.Repo

  @node_ttl_seconds 15

  @type t :: %__MODULE__{in_flight: non_neg_integer(), skip_logged: boolean()}
  defstruct in_flight: 0, skip_logged: false

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reactive burst: provision one more worker if in-flight + live workers is still
  below `max_nodes/0`. Cast by the scheduler when it cannot place a VM.
  """
  @spec request_capacity() :: :ok
  def request_capacity, do: GenServer.cast(__MODULE__, :request_capacity)

  @impl true
  def init(_opts) do
    send(self(), :reconcile)
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_info(:reconcile, state) do
    new_state = reconcile(state)
    Process.send_after(self(), :reconcile, Config.reconcile_interval_ms())
    {:noreply, new_state}
  end

  def handle_info({:provision_done, result}, state) do
    case result do
      {:ok, ref} -> Logger.info("autoscale: provisioned worker #{inspect(ref)}")
      {:error, reason} -> Logger.warning("autoscale: provision failed: #{inspect(reason)}")
    end

    {:noreply, %{state | in_flight: max(0, state.in_flight - 1)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:request_capacity, state) do
    cond do
      not Config.enabled?() ->
        {:noreply, state}

      is_nil(Config.provider_cfg().token) ->
        {:noreply, state}

      live_worker_count() + state.in_flight < Config.max_nodes() ->
        Logger.info("autoscale: reactive capacity request; provisioning 1 worker")
        {:noreply, provision(state, 1)}

      true ->
        {:noreply, state}
    end
  end

  @spec reconcile(t()) :: t()
  defp reconcile(state) do
    cond do
      not Config.enabled?() ->
        log_skip(state, "autoscaling disabled (autoscale.enabled = false)")

      is_nil(Config.provider_cfg().token) ->
        log_skip(state, "LATITUDE_API_TOKEN not set; autoscaler idle")

      true ->
        scale_up(drain_idle(reset_skip(state)))
    end
  end

  @spec scale_up(t()) :: t()
  defp scale_up(state) do
    live = live_worker_count()
    min_n = Config.min_nodes()
    max_n = Config.max_nodes()
    committed = live + state.in_flight
    to_provision = max(0, min(min_n - committed, max_n - committed))

    if to_provision > 0 do
      Logger.info(
        "autoscale: #{live} live workers (+#{state.in_flight} in-flight) below min #{min_n}; " <>
          "provisioning #{to_provision}"
      )
    end

    provision(state, to_provision)
  end

  @spec provision(t(), non_neg_integer()) :: t()
  defp provision(state, n) when n > 0 do
    cfg = Config.provider_cfg()
    provider = Config.provider()
    user_data = UserData.render(cfg)
    parent = self()

    Enum.each(1..n, fn _ -> spawn_provision(provider, cfg, user_data, parent) end)
    %{state | in_flight: state.in_flight + n}
  end

  defp provision(state, _n), do: state

  @spec spawn_provision(module(), map(), String.t(), pid()) :: :ok
  defp spawn_provision(provider, cfg, user_data, parent) do
    {:ok, _pid} =
      Task.start(fn ->
        result = create_node(provider, cfg, user_data)
        send(parent, {:provision_done, result})
      end)

    :ok
  end

  @spec create_node(module(), map(), String.t()) :: {:ok, term()} | {:error, term()}
  defp create_node(provider, cfg, user_data) do
    provider.create_node(cfg, user_data)
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec live_worker_count() :: non_neg_integer()
  defp live_worker_count do
    sql =
      "SELECT count(*) FROM cluster_nodes " <>
        "WHERE role = $1 AND updated_at > now() - interval '#{@node_ttl_seconds} seconds'"

    %{rows: [[count]]} = Ecto.Adapters.SQL.query!(Repo, sql, ["worker"])
    count
  rescue
    e ->
      # On a DB hiccup, report the ceiling so this tick provisions nothing: a
      # transient failure must never trigger a provisioning storm.
      Logger.warning("autoscale: could not count live workers (#{Exception.message(e)}); skipping")
      Config.max_nodes()
  end

  # Automatic idle draining is intentionally a no-op in v1: tearing down a node
  # we just booted risks killing a worker with in-flight VMs the scheduler still
  # counts, so v1 only ever scales up and leaves teardown to an operator.
  @spec drain_idle(t()) :: t()
  defp drain_idle(state), do: state

  @spec log_skip(t(), String.t()) :: t()
  defp log_skip(%__MODULE__{skip_logged: true} = state, _msg), do: state

  defp log_skip(state, msg) do
    Logger.info("autoscale: #{msg}")
    %{state | skip_logged: true}
  end

  @spec reset_skip(t()) :: t()
  defp reset_skip(state), do: %{state | skip_logged: false}
end
