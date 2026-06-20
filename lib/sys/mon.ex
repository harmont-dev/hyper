defmodule Sys.Mon do
  @moduledoc """
  Supervises this node's real-time soft-metric monitors and exposes their current
  readings to the scheduler.

  Each child is an independent `Sys.Mon.Server` sampling one metric on its own
  prime-second period (`Cpu` 2 s, `Mem` 5 s, `DiskBw` 7 s, `NetBw` 11 s - pairwise
  coprime, so their tick phases rarely align) and low-pass-filtering the result.
  `one_for_one`: a crash in one monitor never disturbs the others.

  Telemetry events emitted by the children:

    * `[:sys, :mon, :cpu]`     - CPU utilization fraction
    * `[:sys, :mon, :mem]`     - used memory (bytes)
    * `[:sys, :mon, :disk_bw]` - disk bandwidth (bytes/sec)
    * `[:sys, :mon, :net_bw]`  - net bandwidth (bytes/sec)

  Each carries measurements `%{instant: float, smoothed: float}`.
  """

  use Supervisor

  alias Sys.Mon.{Cpu, DiskBw, Mem, NetBw}

  @doc "Start the monitor supervisor."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg) do
    Supervisor.init([Cpu, Mem, DiskBw, NetBw], strategy: :one_for_one)
  end

  @typedoc "A snapshot of every monitored soft metric."
  @type readings :: %{
          cpu: Sys.Mon.Server.Reading.t(),
          mem: Mem.Reading.t(),
          disk_bw: DiskBw.Reading.t(),
          net_bw: NetBw.Reading.t()
        }

  @doc "The current instantaneous + filtered reading for every monitored metric."
  @spec readings() :: readings()
  def readings do
    %{cpu: Cpu.value(), mem: Mem.value(), disk_bw: DiskBw.value(), net_bw: NetBw.value()}
  end
end
