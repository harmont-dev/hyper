defmodule Sys.Mon.Mem do
  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Meminfo
  alias Sys.Mon.Server
  alias Unit.Information
  alias Unit.Time

  @period_ms 29
  @tau_s 30

  @moduledoc """
  Monitors instantaneous memory pressure.

  Samples `/proc/meminfo` every #{@period_ms} ms and reports *used* memory as
  `MemTotal - MemAvailable`, smoothed with a #{@tau_s}-second time constant. Although
  memory is an alpha (hard) budget tracked from VM specs, the live figure is useful
  for detecting actual pressure. Readings are `Unit.Information`.
  """

  @impl true
  def period, do: Time.ms(@period_ms)

  @impl true
  def tau, do: Time.s(@tau_s)

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
      {:ok, snapshot} -> {:ok, used(snapshot), nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  # Used memory: `MemTotal - MemAvailable`. On any sane reading `available <=
  # total`, so the result is non-negative; the subtraction is not clamped, so a
  # nonsensical `available > total` reading would surface as a negative figure
  # rather than being silently hidden.
  @spec used(Meminfo.Snapshot.t()) :: Information.t()
  def used(%Meminfo.Snapshot{total: total, available: available}) do
    Information.bytes(Information.as_bytes(total) - Information.as_bytes(available))
  end
end
