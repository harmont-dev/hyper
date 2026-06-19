defmodule Sys.Mon.DiskBw do
  @moduledoc """
  Monitors instantaneous disk bandwidth (the soft β_disk_bw signal).

  Samples cumulative read+write bytes across whole physical disks from
  `/proc/diskstats` every 7 seconds and differentiates them into bytes/sec via
  `Controls.Rate` (the first read only establishes a baseline). The rate series is
  smoothed with a 20-second time constant. Readings are `Unit.Bandwidth`.

  Telemetry: `[:sys, :mon, :disk_bw]` with measurements `%{instant: float, smoothed: float}` (bytes/sec).
  """

  @behaviour Sys.Mon.Sampler

  alias Controls.Rate
  alias Sys.Linux.Proc.Diskstats
  alias Sys.Mon.Server
  alias Unit.Bandwidth
  alias Unit.Time

  @period Time.s(7)
  @tau Time.s(20)
  @event [:sys, :mon, :disk_bw]

  defmodule Reading do
    @moduledoc "Instantaneous and filtered disk-bandwidth readings."
    @type t :: %__MODULE__{instant: Bandwidth.t() | nil, smoothed: Bandwidth.t() | nil}
    defstruct [:instant, :smoothed]
  end

  @doc "The latest instantaneous + filtered disk bandwidth."
  @spec value() :: Reading.t()
  def value do
    %Server.Reading{instant: instant, smoothed: smoothed} = Server.value(__MODULE__)
    %Reading{instant: to_bw(instant), smoothed: to_bw(smoothed)}
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
  def sample(rate_state) do
    case Diskstats.read_total_physical() do
      {:ok, bytes} ->
        Rate.compute(rate_state, bytes, System.monotonic_time(:millisecond))

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec to_bw(float() | nil) :: Bandwidth.t() | nil
  defp to_bw(nil), do: nil
  defp to_bw(bytes_per_sec), do: Bandwidth.bps(round(bytes_per_sec))
end
