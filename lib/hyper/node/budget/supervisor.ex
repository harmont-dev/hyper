defmodule Hyper.Node.Budget.Supervisor do
  @moduledoc """
  Per-node supervisor for the budget subsystem. Runs once per BEAM node and
  supervises the single `Hyper.Node.Budget.Hard` accounting GenServer, and
  nothing else.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [Hyper.Node.Budget.Hard]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
