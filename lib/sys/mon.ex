defmodule Sys.Mon do
  @moduledoc """
  Supervises this node's real-time resource monitors and exposes their current
  readings to the scheduler via `readings/0`.
  """

  use Supervisor

  alias Sys.Mon.{Cpu, DiskBw, Mem, NetBw}

  defmodule Readings do
    @moduledoc """
    A snapshot of every monitored soft metric at one instant. Each field is a
    `Sys.Mon.Server.Reading` whose `instant`/`smoothed` carry that metric's domain
    type - `cpu` a `Float` fraction, `mem` a `Unit.Information`, `disk_bw`/`net_bw`
    a `Unit.Bandwidth`.
    """
    @type t :: %__MODULE__{
            cpu: Sys.Mon.Server.Reading.t(),
            mem: Sys.Mon.Server.Reading.t(),
            disk_bw: Sys.Mon.Server.Reading.t(),
            net_bw: Sys.Mon.Server.Reading.t()
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
