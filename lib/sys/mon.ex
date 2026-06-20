defmodule Sys.Mon do
  @moduledoc """
  Supervises this node's real-time resource monitors and exposes their current
  readings to the scheduler.

  Telemetry events emitted by the children:

    * `[:sys, :mon, :cpu]`     - CPU utilization fraction
    * `[:sys, :mon, :mem]`     - used memory (bytes)
    * `[:sys, :mon, :disk_bw]` - disk bandwidth (bytes/sec)
    * `[:sys, :mon, :net_bw]`  - net bandwidth (bytes/sec)

  Each carries measurements `%{instant: float, smoothed: float}`.
  """

  use Supervisor

  alias Sys.Mon.{Cpu, DiskBw, Mem, NetBw}

  defmodule Readings do
    @moduledoc "A snapshot of every monitored soft metric at one instant."
    @type t :: %__MODULE__{
            cpu: Sys.Mon.Server.Reading.t(),
            mem: Mem.Reading.t(),
            disk_bw: DiskBw.Reading.t(),
            net_bw: NetBw.Reading.t()
          }
    @enforce_keys [:cpu, :mem, :disk_bw, :net_bw]
    defstruct [:cpu, :mem, :disk_bw, :net_bw]
  end

  @doc "Start the monitor supervisor."
  @spec start_link(term()) :: Supervisor.on_start()
  def start_link(_arg), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_arg) do
    Supervisor.init([Cpu, Mem, DiskBw, NetBw], strategy: :one_for_one)
  end

  @doc "The current instantaneous + filtered reading for every monitored metric."
  @spec readings() :: Readings.t()
  def readings do
    %Readings{cpu: Cpu.value(), mem: Mem.value(), disk_bw: DiskBw.value(), net_bw: NetBw.value()}
  end
end
