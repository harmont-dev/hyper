defmodule Hyper.Node.FireVMM.GuestServices.Supervisor do
  @moduledoc false

  use Supervisor

  alias Hyper.Node.FireVMM.GuestServices.Listener
  alias Hyper.Node.FireVMM.Opts

  @spec child_spec(Opts.t()) :: Supervisor.child_spec()
  def child_spec(%Opts{} = opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary,
      shutdown: 10_000
    }
  end

  @spec start_link(Opts.t()) :: Supervisor.on_start()
  def start_link(%Opts{} = opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(%Opts{vm_id: vm_id, gid: gid, guest_services: services}) do
    listener = %Listener.Opts{vm_id: vm_id, gid: gid, services: services}

    Supervisor.init([{Listener, listener}],
      strategy: :one_for_one,
      max_restarts: 3,
      max_seconds: 60
    )
  end
end
