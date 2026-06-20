defmodule Hyper.Node.Budget.Supervisor do
  @moduledoc """
  Per-node supervisor for the budget subsystem. Runs once per BEAM node and owns
  both sides of the budget:

    * `Hyper.Node.Budget.Hard` - hard memory/disk accounting from VM specs.
    * `Sys.Mon` - real-time soft-metric monitors (CPU/disk/net) backing
      `Hyper.Node.Budget.Soft`.

  The two are independent (`:one_for_one`): a crash in the monitors does not
  reset the hard ledger, and vice versa.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [Hyper.Node.Budget.Hard, Sys.Mon]
    Supervisor.init(children, strategy: :one_for_one)
  end
end
