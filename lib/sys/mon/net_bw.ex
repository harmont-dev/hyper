defmodule Sys.Mon.NetBw do
  @moduledoc """
  Monitors instantaneous network bandwidth (the soft beta_net_bw signal).

  Samples cumulative rx+tx bytes across non-loopback interfaces from
  `/proc/net/dev` every 11 seconds and differentiates them into bytes/sec via
  `Controls.Rate` (the first read only establishes a baseline). The rate series is
  smoothed with a 20-second time constant. Readings are `Unit.Bandwidth`.

  Telemetry: `[:sys, :mon, :net_bw]` with measurements `%{instant: float, smoothed: float}` (bytes/sec).
  """

  @behaviour Sys.Mon.Sampler

  alias Controls.Rate
  alias Sys.Linux.Proc.NetDev
  alias Sys.Mon.Server
  alias Unit.Bandwidth
  alias Unit.Time

  @period Time.s(11)
  @tau Time.s(20)
  @event [:sys, :mon, :net_bw]

  defmodule Reading do
    @moduledoc "Instantaneous and filtered net-bandwidth readings."
    @type t :: %__MODULE__{instant: Bandwidth.t() | nil, smoothed: Bandwidth.t() | nil}
    defstruct [:instant, :smoothed]
  end

  @doc "The latest instantaneous + filtered network bandwidth."
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
    case NetDev.read_total() do
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
