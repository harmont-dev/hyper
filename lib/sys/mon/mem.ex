defmodule Sys.Mon.Mem do
  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Meminfo
  alias Sys.Mon.Server
  alias Unit.Information
  alias Unit.Time

  @period_ms 29
  @tau_s 30
  @event [:sys, :mon, :mem]

  @moduledoc """
  Monitors instantaneous memory pressure.

  Samples `/proc/meminfo` every #{@period_ms} ms and reports *used* memory as
  `MemTotal - MemAvailable`, smoothed with a #{@tau_s}-second time constant. Although
  memory is an alpha (hard) budget tracked from VM specs, the live figure is useful
  for detecting actual pressure. Readings are `Unit.Information`.

  Telemetry: `#{inspect(@event)}` with measurements `%{instant: float, smoothed: float}` (bytes).
  """

  @impl true
  def period, do: Time.ms(@period_ms)

  @impl true
  def tau, do: Time.s(@tau_s)

  @impl true
  def telemetry_event, do: @event

  @doc "The latest instantaneous + filtered used memory (`Unit.Information` readings)."
  @spec value() :: Server.Reading.t()
  def value, do: Server.value(__MODULE__)

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: %{id: __MODULE__, start: {Server, :start_link, [__MODULE__]}}

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(_state) do
    case Meminfo.read() do
      {:ok, %Meminfo.Snapshot{total: total, available: available}} ->
        used = Information.as_bytes(total) - Information.as_bytes(available)
        {:ok, Information.bytes(used), nil}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
