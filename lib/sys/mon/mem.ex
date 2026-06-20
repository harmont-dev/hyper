defmodule Sys.Mon.Mem do
  @moduledoc """
  Monitors instantaneous memory pressure.

  Samples `/proc/meminfo` every 5 seconds and reports *used* memory as
  `MemTotal - MemAvailable`, smoothed with a 30-second time constant. Although
  memory is an alpha (hard) budget tracked from VM specs, the live figure is useful
  for detecting actual pressure. Readings are `Unit.Information`.

  Telemetry: `[:sys, :mon, :mem]` with measurements `%{instant: float, smoothed: float}` (bytes).
  """

  @behaviour Sys.Mon.Sampler

  alias Sys.Linux.Proc.Meminfo
  alias Sys.Mon.Server
  alias Unit.Information
  alias Unit.Time

  @period Time.s(5)
  @tau Time.s(30)
  @event [:sys, :mon, :mem]

  defmodule Reading do
    @moduledoc "Instantaneous and filtered used-memory readings."
    @type t :: %__MODULE__{instant: Information.t() | nil, smoothed: Information.t() | nil}
    defstruct [:instant, :smoothed]
  end

  @doc "The latest instantaneous + filtered used memory."
  @spec value() :: Reading.t()
  def value do
    %Server.Reading{instant: instant, smoothed: smoothed} = Server.value(__MODULE__)
    %Reading{instant: to_info(instant), smoothed: to_info(smoothed)}
  end

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg) do
    opts = %Server.Opts{
      sampler: __MODULE__,
      period: @period,
      tau: @tau,
      name: __MODULE__,
      telemetry_event: @event
    }

    %{id: __MODULE__, start: {Server, :start_link, [opts]}}
  end

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(_state) do
    case Meminfo.read() do
      {:ok, %Meminfo.Snapshot{total: total, available: available}} ->
        used = Information.as_bytes(total) - Information.as_bytes(available)
        {:ok, used * 1.0, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_info(float() | nil) :: Information.t() | nil
  defp to_info(nil), do: nil
  defp to_info(bytes), do: Information.bytes(round(bytes))
end
