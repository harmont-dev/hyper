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

  A provisioned machine is *committed capacity* long before it is *live*: the
  provider returns as soon as the machine is RUNNING, but the node only shows up
  in `cluster_nodes` once its bootstrap script has installed and started Hyper,
  which takes minutes. Counting only live + in-flight machines therefore orders a
  new machine on every tick of that gap. So a successful create moves into
  `:pending`, where it is counted as committed until either its
  `Hyper.Cfg.Autoscale.provision_timeout_ms/0` deadline passes or the live worker
  count has risen to cover it.

  Everything is demo-grade and best-effort: failures are logged via `Logger` and
  never crash the process. Provisioning runs in an unlinked `Task` so a slow or
  failing provider API call cannot block the reconcile loop.
  """

  use GenServer
  require Logger

  alias Hyper.Cfg.Autoscale, as: Config
  alias Hyper.Img.Db.Repo

  @node_ttl_seconds 15

  @type t :: %__MODULE__{
          in_flight: non_neg_integer(),
          pending: %{optional(String.t()) => integer()},
          pending_baseline: non_neg_integer(),
          skip_logged: boolean()
        }
  defstruct in_flight: 0, pending: %{}, pending_baseline: 0, skip_logged: false

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Reactive burst: provision one more worker if committed capacity (live +
  in-flight + pending) is still below `max_nodes/0`. Cast by the scheduler when
  it cannot place a VM.
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
    state = %{state | in_flight: max(0, state.in_flight - 1)}

    case result do
      {:ok, ref} ->
        Logger.info("autoscale: provisioned worker #{inspect(ref)}; awaiting bootstrap")
        {:noreply, add_pending(state, ref)}

      {:error, reason} ->
        Logger.warning("autoscale: provision failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:request_capacity, state) do
    with true <- Config.enabled?(),
         :ok <- validate_provider() do
      if committed(state, live_worker_count()) < Config.max_nodes() do
        Logger.info("autoscale: reactive capacity request; provisioning 1 worker")
        {:noreply, provision(state, 1)}
      else
        {:noreply, state}
      end
    else
      _ -> {:noreply, state}
    end
  end

  @spec reconcile(t()) :: t()
  defp reconcile(state) do
    cond do
      not Config.enabled?() ->
        log_skip(state, "autoscaling disabled (autoscale.enabled = false)")

      match?({:error, _}, validate_provider()) ->
        {:error, reason} = validate_provider()
        log_skip(state, "provider #{inspect(Config.provider())} not usable: #{inspect(reason)}")

      true ->
        live = live_worker_count()

        state
        |> reset_skip()
        |> retire_pending(live)
        |> drain_idle()
        |> scale_up(live)
    end
  end

  @spec validate_provider() :: :ok | {:error, term()}
  defp validate_provider do
    provider = Config.provider()
    provider.validate_cfg(Config.provider_cfg())
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec committed(t(), non_neg_integer()) :: non_neg_integer()
  defp committed(%__MODULE__{in_flight: in_flight, pending: pending}, live)
       when is_integer(live) and is_integer(in_flight),
       do: live + in_flight + map_size(pending)

  @spec add_pending(t(), term()) :: t()
  defp add_pending(state, ref) do
    deadline = System.monotonic_time(:millisecond) + Config.provision_timeout_ms()

    baseline =
      if map_size(state.pending) == 0, do: live_worker_count(), else: state.pending_baseline

    %{
      state
      | pending: Map.put(state.pending, pending_key(ref), deadline),
        pending_baseline: baseline
    }
  end

  @spec pending_key(term()) :: String.t()
  defp pending_key(%{ref: ref}) when is_binary(ref), do: ref
  defp pending_key(other), do: inspect(other)

  @spec retire_pending(t(), non_neg_integer()) :: t()
  defp retire_pending(%__MODULE__{pending: pending} = state, _live) when map_size(pending) == 0,
    do: state

  defp retire_pending(state, live) do
    now = System.monotonic_time(:millisecond)
    kept = Map.filter(state.pending, fn {_key, deadline} -> deadline > now end)

    kept =
      if map_size(kept) > 0 and live >= state.pending_baseline + map_size(kept),
        do: %{},
        else: kept

    if map_size(kept) != map_size(state.pending) do
      Logger.info(
        "autoscale: retired #{map_size(state.pending) - map_size(kept)} pending provision(s); " <>
          "#{map_size(kept)} still awaiting bootstrap"
      )
    end

    %{state | pending: kept}
  end

  @spec scale_up(t(), non_neg_integer()) :: t()
  defp scale_up(state, live) do
    min_n = Config.min_nodes()
    max_n = Config.max_nodes()
    committed = committed(state, live)
    to_provision = max(0, min(min_n - committed, max_n - committed))

    if to_provision > 0 do
      Logger.info(
        "autoscale: #{live} live workers (+#{state.in_flight} in-flight, " <>
          "+#{map_size(state.pending)} pending) below min #{min_n}; provisioning #{to_provision}"
      )
    end

    provision(state, to_provision)
  end

  @spec provision(t(), non_neg_integer()) :: t()
  defp provision(state, n) when is_integer(n) and n > 0 do
    cfg = Config.provider_cfg()
    provider = Config.provider()
    parent = self()

    case render_user_data(provider, cfg) do
      {:ok, user_data} ->
        Enum.each(1..n, fn _ -> spawn_provision(provider, cfg, user_data, parent) end)
        %{state | in_flight: state.in_flight + n}

      {:error, reason} ->
        Logger.error("autoscale: refusing to provision: #{inspect(reason)}")
        state
    end
  end

  defp provision(state, _n), do: state

  @spec render_user_data(module(), map()) :: {:ok, String.t()} | {:error, term()}
  defp render_user_data(provider, cfg) do
    path = Application.app_dir(:hyper, provider.template_segments())

    if File.regular?(path) do
      assigns = [
        release_url: cfg[:release_url],
        pg_url: cfg[:pg_url],
        cookie: cfg[:cookie],
        resolver: cfg[:resolver],
        hostname: hostname(cfg)
      ]

      {:ok, EEx.eval_file(path, assigns: assigns)}
    else
      {:error, {:template_missing, path}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @spec hostname(map()) :: String.t()
  defp hostname(cfg) do
    prefix = cfg[:hostname_prefix] || "hyper-worker"
    "#{prefix}-#{:erlang.unique_integer([:positive])}"
  end

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
      Logger.warning(
        "autoscale: could not count live workers (#{Exception.message(e)}); skipping"
      )

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
