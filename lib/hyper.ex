defmodule Hyper do
  @moduledoc """
  `Hyper` is a distrubuted elixir virtual machine orchestrator.
  """

  @type vm :: pid()

  @type vm_source ::
    {:image, kernel: Path.t(), rootfs: Path.t()}
    | {:snapshot, Path.t()}
    | {:vm, vm()}

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

  @doc """
  Fork an existing virtual machine into another virtual machine.

  This effectively creates a new virtual machine in the same state as the previous virtual machine.

  This cast will attempt to co-locate VMs on the same `Hyper.Node` as the parent VM, as that
  ensures the fastest possible bootup time.

  If, however, the candidate node is currently overloaded, this will create a
  snapshot of the given VM, and will create the requested VM on the most available node.
  """
  @impl true
  def handle_cast({:create_vm, %{source: {:vm, _vm}}}, state) do
    Tracer.with_span "hyper.create_vm" do
      Tracer.set_attribute("vm.source.type", "vm")
      # ... clone from a running VM ...
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:create_vm, %{source: {:snapshot, _snapshot}}}, _from, state) do
    Tracer.with_span "hyper.create_vm" do
      Tracer.set_attribute("vm.source.type", "snapshot")
      # ... restore from a snapshot ...
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:create_vm, %{source: {:image, _kernel, _rootfs}}}, _from, state) do
    Tracer.with_span "hyper.create_vm" do
      Tracer.set_attribute("vm.source.type", "image")
      # ... boot from a kernel + rootfs image ...
      {:reply, :ok, state}
    end
  end
end
