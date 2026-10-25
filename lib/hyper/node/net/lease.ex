defmodule Hyper.Node.Net.Lease do
  @moduledoc """
  A VM's network managed by a process bound to the lifetime of the VM.
  """

  use GenServer, restart: :temporary

  alias Hyper.Node.Net.Ip

  @enforce_keys [:vm_id, :netns, :ip]
  defstruct [:vm_id, :netns, :ip]

  @type t :: %__MODULE__{
          vm_id: Hyper.Vm.Id.t(),
          netns: String.t(),
          ip: Ip.Lease.t()
        }

  @type opts :: [vm_id: Hyper.Vm.Id.t(), uid: Hyper.Node.Users.id(), owner: pid()]

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(_opts), do: {:stop, :unimplemented}
end
