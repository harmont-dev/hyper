defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  @type vm_source ::
    {:snapshot, Path.t()}
    | {:vm, Hyper.Vm.t()}

  @typedoc """
  The specification for creating a new VM.
  """
  @type vm_spec :: %{
    required(:source) => vm_source(),
  }

  use GenServer
  require OpenTelemetry.Tracer, as: Tracer

  @impl true
  def init(state) do
    {:ok, state}
  end

  @impl true
  def handle_call({:create_vm, _source}, _from, state) do
    {:noreply, state}
  end

  @doc """
  Fork an existing virtual machine into another virtual machine.

  This effectively creates a new virtual machine in the same state as the previous virtual machine.

  This cast will attempt to co-locate VMs on the same `Hyper.Node` as the parent VM, as that
  ensures the fastest possible bootup time.

  If, however, the candidate node is currently overloaded, this will create a
  snapshot of the given VM, and will create the requested VM on the most available node.
  """
  def create_vm(%{source: {:vm, vm}}) do
    GenServer.call(__MODULE__, {:create_vm, %{source: {:vm, vm}}})
  end

  @doc "Create a new virtual machine with the given snapshot."
  def create_vm(%{source: {:snapshot, snapshot}}) do
    GenServer.call(__MODULE__, {:create_vm, %{source: {:snapshot, snapshot}}})
  end
end
