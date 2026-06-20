defmodule Sys.Mon.NetBw do
  @behaviour Sys.Mon.Sampler

  alias Controls.Rate
  alias Sys.Linux.Proc.NetDev
  alias Sys.Mon.Server
  alias Unit.Bandwidth
  alias Unit.Time

  @period_ms 37
  @tau_s 20
  @event [:sys, :mon, :net_bw]

  @moduledoc """
  Monitors instantaneous network bandwidth (the soft beta_net_bw signal).

  Samples cumulative rx+tx bytes across non-loopback interfaces from
  `/proc/net/dev` every #{@period_ms} ms and differentiates them into bytes/sec via
  `Controls.Rate` (the first read only establishes a baseline). The rate series is
  smoothed with a #{@tau_s}-second time constant. Readings are `Unit.Bandwidth`.

  Telemetry: `#{inspect(@event)}` with measurements `%{instant: float, smoothed: float}` (bytes/sec).
  """

  @impl true
  def period, do: Time.ms(@period_ms)

  @impl true
  def tau, do: Time.s(@tau_s)

  @impl true
  def telemetry_event, do: @event

  @doc "The latest instantaneous + filtered network bandwidth (`Unit.Bandwidth` readings)."
  @spec value() :: Server.Reading.t()
  def value, do: Server.value(__MODULE__)

  @doc false
  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_arg), do: %{id: __MODULE__, start: {Server, :start_link, [__MODULE__]}}

  @impl true
  def init, do: {:ok, nil}

  @impl true
  def sample(rate_state) do
    case NetDev.read_total() do
      {:ok, bytes} ->
        rate_state
        |> Rate.compute(bytes, System.monotonic_time(:millisecond))
        |> as_bandwidth()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Project the raw bytes/sec rate into a `Unit.Bandwidth` reading.
  @spec as_bandwidth({:ok, float(), Rate.state()} | {:skip, Rate.state()}) ::
          {:ok, Bandwidth.t(), Rate.state()} | {:skip, Rate.state()}
  defp as_bandwidth({:ok, bytes_per_sec, state}),
    do: {:ok, Bandwidth.bps(round(bytes_per_sec)), state}

  defp as_bandwidth({:skip, state}), do: {:skip, state}
end
