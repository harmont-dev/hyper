defmodule Hyper.Node.FireVMM.Client do
  @moduledoc """
  Per-microVM facade over the generated Firecracker API
  (`Hyper.Firecracker.Api.Operations`). One GenServer per VM, registered
  cluster-wide via `Hyper.Cluster.Routing.via({vm_id, :client})`. It holds the
  VM's API socket path and serializes every request through `handle_call`
  (Firecracker's API server is single-threaded).

  Call any generated operation through `run/2`, passing a 1-arity closure that
  receives the per-call opts (carrying `:socket_path`) to forward as the
  operation's trailing `opts` argument:

      alias Hyper.Firecracker.Api.Operations

      Client.run(Client.via(vm_id), &Operations.describe_instance/1)

      Client.run(Client.via(vm_id), fn opts ->
        Operations.put_guest_boot_source(%Hyper.Firecracker.Api.BootSource{
          kernel_image_path: "/vmlinux"
        }, opts)
      end)

  The closure's return value (`:ok` / `{:ok, struct}` / `{:error, _}` from
  `Hyper.Firecracker.Api.Transport`) is returned to the caller unchanged.
  """

  use GenServer

  @call_timeout 35_000

  defmodule Opts do
    @moduledoc "Start options for `Hyper.Node.FireVMM.Client`."
    @enforce_keys [:vm_id, :socket_path]
    defstruct [:vm_id, :socket_path, :name]

    @type t :: %__MODULE__{
            vm_id: integer() | nil,
            socket_path: Path.t(),
            name: GenServer.name() | nil
          }
  end

  defmodule State do
    @moduledoc false
    @enforce_keys [:socket_path]
    defstruct [:socket_path]
    @type t :: %__MODULE__{socket_path: Path.t()}
  end

  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts) do
    name =
      case opts.name do
        nil when not is_nil(opts.vm_id) -> via(opts.vm_id)
        other -> other
      end

    GenServer.start_link(__MODULE__, opts, gen_opts(name))
  end

  @spec via(integer()) :: GenServer.name()
  def via(vm_id), do: Hyper.Cluster.Routing.via({vm_id, :client})

  @doc "Run a generated operation against this VM's daemon, serialized."
  @spec run(GenServer.server(), (keyword() -> result)) :: result when result: var
  def run(server, op_fun) when is_function(op_fun, 1) do
    GenServer.call(server, {:run, op_fun}, @call_timeout)
  end

  @impl true
  @spec init(Opts.t()) :: {:ok, State.t()}
  def init(%Opts{socket_path: socket_path}), do: {:ok, %State{socket_path: socket_path}}

  @impl true
  def handle_call({:run, op_fun}, _from, %State{socket_path: socket_path} = state) do
    {:reply, op_fun.(socket_path: socket_path), state}
  end

  @spec gen_opts(GenServer.name() | nil) :: [{:name, GenServer.name()}]
  defp gen_opts(nil), do: []
  defp gen_opts(name), do: [name: name]
end
