defmodule Hyper.Node.Net do
  @moduledoc """
  Node network configuration.

  `Hyper.Node.Reclaim` purges stale networks at boot and `Hyper.Node.Reaper` reaps
  netns with no live lease.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts), do: :ignore

  @doc "Prepare a `vm_id`'s network under a new `Hyper.Node.Net.Lease`."
  @spec attach(Hyper.Vm.Id.t(), Hyper.Node.Users.id(), pid()) :: no_return()
  def attach(_vm_id, _uid, _owner),
    do: raise("Hyper.Node.Net.attach/3 is unimplemented: VM networking is being rewritten")

  @doc "Stop `vm_id`'s lease, tearing its network down."
  @spec detach(Hyper.Vm.Id.t()) :: no_return()
  def detach(_vm_id),
    do: raise("Hyper.Node.Net.detach/1 is unimplemented: VM networking is being rewritten")

  @doc "Get a `vm_id`'s lease."
  @spec lookup(Hyper.Vm.Id.t()) :: no_return()
  def lookup(_vm_id),
    do: raise("Hyper.Node.Net.lookup/1 is unimplemented: VM networking is being rewritten")
end
