defmodule Hyper.Node.FireVMM.Policy do
  @moduledoc """
  The VM's current port policy. It lives beside `Hyper.Node.FireVMM.Core`, not in
  it, so a firecracker crash (which restarts `Core`'s `Daemon` and `State`
  together) relaunches the VM with the policy last set rather than the one it
  was created with.
  """

  use Agent

  alias Hyper.Node.FireVMM.Opts
  alias Hyper.Vm.Firewall

  @registry Hyper.Node.FireVMM.Policy.Registry

  @spec registry() :: atom()
  def registry, do: @registry

  @spec start_link(Opts.t()) :: Agent.on_start()
  def start_link(%Opts{vm_id: vm_id, firewall: %Firewall{} = firewall}) do
    Agent.start_link(fn -> firewall end, name: via(vm_id))
  end

  @spec child_spec(Opts.t()) :: Supervisor.child_spec()
  def child_spec(%Opts{} = opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "The policy the VM `vm_id` runs under now."
  @spec current(Hyper.Vm.Id.t()) :: Firewall.t()
  def current(vm_id), do: Agent.get(via(vm_id), & &1)

  @doc "Record that the VM `vm_id` now runs under `firewall`."
  @spec put(Hyper.Vm.Id.t(), Firewall.t()) :: :ok
  def put(vm_id, %Firewall{} = firewall), do: Agent.update(via(vm_id), fn _ -> firewall end)

  defp via(vm_id), do: {:via, Registry, {@registry, vm_id}}
end
