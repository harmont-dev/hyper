defmodule Hyper.Cluster.LayerAuditor do
  @moduledoc """
  Cluster-singleton auditor: asserts that every `:present` blob the database
  knows about is actually on the shared medium, at the right size.

  ## Why a singleton, and how it restarts cleanly

  Every node runs this process, but only one is *active* at a time: each contends
  for the `{:singleton, :layer_auditor}` key in the `Hyper.Cluster.Routing` Horde
  registry. The winner audits; the rest stand by and re-contend every
  `acquire_interval`. When the active node (or process) dies its registration
  drops out of the DeltaCRDT, and the next standby retry takes over - so the audit
  resumes within one acquire interval without a Horde.DynamicSupervisor (which the
  cluster deliberately avoids to prevent ghost restarts).

  ## How it walks the database

  It pages through `blobs` by keyset on the primary key
  (`Hyper.Img.Db.Blob.scan_present_after/2`), never `SELECT *`, releasing the DB
  connection between batches because each row triggers a slow shared-medium check.
  Before every batch it guards on `Hyper.Node.Layer.Repo.test_system/0`: if the
  medium is not mounted it reschedules without querying, so a node with no shared
  medium (dev, test) stays completely inert.

  ## What it asserts, and what it does about gaps

  Per blob it looks the file up via `Hyper.Node.Layer.Repo.find_layer/1` and
  `File.stat/1`, classifying present / missing / size-mismatch. Discrepancies are
  surfaced as telemetry and warnings; remediation is intentionally out of scope.

  ## Telemetry

    * `[:hyper, :cluster, :layer_auditor, :sweep, :start]` - measurements `%{}`,
      metadata `%{node: node()}`
    * `[:hyper, :cluster, :layer_auditor, :sweep, :stop]` - measurements
      `%{scanned, present, missing, mismatch}`, metadata `%{node: node()}`
    * `[:hyper, :cluster, :layer_auditor, :discrepancy]` - measurements
      `%{expected, actual}` (actual is 0 for missing), metadata
      `%{blob_id, kind: :missing | :mismatch}`
  """

  use GenServer
  require Logger

  alias Hyper.Cluster.LayerAuditor.Sweep
  alias Hyper.Cluster.Routing
  alias Hyper.Img.Db.Blob
  alias Hyper.Node.Layer.Repo, as: LayerRepo

  @singleton_key {:singleton, :layer_auditor}

  @defaults [
    batch_size: 500,
    # Pause between keyset pages within one sweep.
    batch_pause_ms: 0,
    # Idle gap between completed sweeps.
    sweep_interval_ms: 3_600_000,
    # How often a standby retries to become active.
    acquire_interval_ms: 5_000,
    # Backoff before retrying a sweep when the medium is unavailable.
    medium_retry_ms: 60_000
  ]

  defstruct [:cfg, role: :standby, sweep: nil, last_sweep: nil]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Local role + last completed sweep, for introspection on this node."
  @spec status() :: %{role: :active | :standby, last_sweep: Sweep.t() | nil}
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(opts) do
    cfg =
      @defaults
      |> Keyword.merge(Application.get_env(:hyper, __MODULE__, []))
      |> Keyword.merge(opts)

    {:ok, %__MODULE__{cfg: cfg}, {:continue, :acquire}}
  end

  @impl true
  def handle_continue(:acquire, state), do: {:noreply, acquire(state)}

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{role: state.role, last_sweep: state.last_sweep}, state}
  end

  @impl true
  def handle_info(:acquire, %__MODULE__{role: :standby} = state) do
    {:noreply, acquire(state)}
  end

  # A late acquire tick after we already won: ignore.
  def handle_info(:acquire, state), do: {:noreply, state}

  def handle_info(:sweep, %__MODULE__{role: :active} = state) do
    emit([:sweep, :start], %{}, %{node: node()})
    send(self(), :scan)
    {:noreply, %{state | sweep: Sweep.new()}}
  end

  def handle_info(:scan, %__MODULE__{role: :active} = state) do
    case LayerRepo.test_system() do
      :ok ->
        {:noreply, scan_one_batch(state)}

      {:error, reason} ->
        Logger.warning("layer audit: shared medium unavailable (#{inspect(reason)}); retrying")
        Process.send_after(self(), :sweep, cfg(state, :medium_retry_ms))
        {:noreply, %{state | sweep: nil}}
    end
  end

  # Stale timers delivered after losing/never-having the active role: ignore.
  def handle_info(msg, state) when msg in [:sweep, :scan], do: {:noreply, state}

  ## Internals

  @spec acquire(%__MODULE__{}) :: %__MODULE__{}
  defp acquire(state) do
    case Horde.Registry.register(Routing.name(), @singleton_key, nil) do
      {:ok, _pid} ->
        Logger.info("layer audit: this node is now the active auditor")
        send(self(), :sweep)
        %{state | role: :active}

      {:error, {:already_registered, _pid}} ->
        Process.send_after(self(), :acquire, cfg(state, :acquire_interval_ms))
        %{state | role: :standby}
    end
  end

  @spec scan_one_batch(%__MODULE__{}) :: %__MODULE__{}
  defp scan_one_batch(%__MODULE__{sweep: sweep} = state) do
    limit = cfg(state, :batch_size)
    batch = Blob.scan_present_after(sweep.cursor, limit)
    {sweep, outcomes} = Sweep.absorb(sweep, batch, &check_blob/1)
    Enum.each(outcomes, &report/1)

    if Sweep.continue?(batch, limit) do
      Process.send_after(self(), :scan, cfg(state, :batch_pause_ms))
      %{state | sweep: sweep}
    else
      emit(
        [:sweep, :stop],
        %{
          scanned: sweep.scanned,
          present: sweep.present,
          missing: sweep.missing,
          mismatch: sweep.mismatch
        },
        %{node: node()}
      )

      Logger.info(
        "layer audit complete: scanned=#{sweep.scanned} present=#{sweep.present} " <>
          "missing=#{sweep.missing} mismatch=#{sweep.mismatch}"
      )

      Process.send_after(self(), :sweep, cfg(state, :sweep_interval_ms))
      %{state | sweep: nil, last_sweep: sweep}
    end
  end

  # Shared-medium probe injected into the pure Sweep core.
  @spec check_blob(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  defp check_blob(id) do
    with {:ok, path} <- LayerRepo.find_layer(id),
         {:ok, %File.Stat{size: size}} <- File.stat(path) do
      {:ok, size}
    else
      {:error, :not_found} -> {:error, :not_found}
      # A file that vanishes between find and stat counts as missing.
      {:error, _posix} -> {:error, :not_found}
    end
  end

  @spec report(Sweep.outcome()) :: :ok
  defp report(:present), do: :ok

  defp report({:missing, id}) do
    Logger.warning("layer audit: blob #{id} missing from shared medium")
    emit([:discrepancy], %{expected: 0, actual: 0}, %{blob_id: id, kind: :missing})
  end

  defp report({:mismatch, id, expected, actual}) do
    Logger.warning("layer audit: blob #{id} size mismatch expected=#{expected} actual=#{actual}")
    emit([:discrepancy], %{expected: expected, actual: actual}, %{blob_id: id, kind: :mismatch})
  end

  @spec emit([atom()], map(), map()) :: :ok
  defp emit(suffix, measurements, metadata) do
    :telemetry.execute([:hyper, :cluster, :layer_auditor | suffix], measurements, metadata)
  end

  @spec cfg(%__MODULE__{}, atom()) :: term()
  defp cfg(%__MODULE__{cfg: cfg}, key), do: Keyword.fetch!(cfg, key)
end
