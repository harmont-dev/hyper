defmodule Sys.Mon.NetBw do
  @behaviour Sys.Mon.Sampler

  alias Controls.Rate
  alias Sys.Linux.Proc.NetDev
  alias Sys.Mon.Server
  alias Unit.Bandwidth

  @moduledoc """
  Monitors instantaneous network bandwidth (the soft beta_net_bw signal).

  Samples cumulative rx+tx bytes across physical interfaces from `/proc/net/dev`
  every 37 ms and differentiates them into bytes/sec via `Controls.Rate`
  (the first read only establishes a baseline). The rate series is smoothed with a
  20-second time constant. Readings are `Unit.Bandwidth`.
  """

  # Prime sampling period, co-prime with the sibling monitors so their reads
  # rarely land on the same tick.
  @impl true
  @spec period :: Unit.Time.t()
  def period, do: Unit.Time.ms(37)

  @impl true
  @spec tau :: Unit.Time.t()
  def tau, do: Unit.Time.s(20)

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
    case NetDev.read() do
      {:ok, interfaces} ->
        rate_state
        |> Rate.compute(physical_bytes(interfaces), System.monotonic_time(:millisecond))
        |> as_bandwidth()

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Sum rx+tx across physical interfaces only. A physical NIC exposes a backing
  # device at /sys/class/net/<if>/device; loopback, bridges, docker/veth, and
  # tunnels do not - this is the kernel's own distinction, so it needs no fragile
  # interface-name patterns. Counting bridges/tunnels would also double-count
  # traffic that still traverses the physical NIC.
  @spec physical_bytes([NetDev.Interface.t()]) :: non_neg_integer()
  defp physical_bytes(interfaces) do
    interfaces
    |> Enum.filter(&physical?(&1.name))
    |> sum_bytes()
  end

  @spec physical?(String.t()) :: boolean()
  defp physical?(name), do: File.exists?("/sys/class/net/#{name}/device")

  @doc false
  # Total rx+tx bytes across the given interfaces. Pure: the physical-interface
  # filtering happens upstream, so this is exactly the cumulative-counter
  # denominator handed to `Rate`.
  @spec sum_bytes([NetDev.Interface.t()]) :: non_neg_integer()
  def sum_bytes(interfaces) do
    Enum.reduce(interfaces, 0, fn i, acc -> acc + i.rx_bytes + i.tx_bytes end)
  end

  @doc false
  # Project the raw bytes/sec rate into a `Unit.Bandwidth` reading; `:skip`
  # (no baseline yet) passes through untouched.
  @spec as_bandwidth({:ok, float(), Rate.state()} | {:skip, Rate.state()}) ::
          {:ok, Bandwidth.t(), Rate.state()} | {:skip, Rate.state()}
  def as_bandwidth({:ok, bytes_per_sec, state}),
    do: {:ok, Bandwidth.bps(round(bytes_per_sec)), state}

  def as_bandwidth({:skip, state}), do: {:skip, state}
end
