defmodule Hyper.Node.Net do
  @moduledoc """
  Node network configuration.

  `Hyper.Node.Reclaim` purges stale networks at boot and `Hyper.Node.Reaper` reaps
  netns with no live lease.
  """

  use GenServer

  alias Hyper.Node.Net.Ip

  @type id :: non_neg_integer()

  defmodule State do
    @moduledoc false

    @enforce_keys [:host, :max, :next]
    defstruct [:host, :max, :next, freed: [], owners: %{}]

    @type t :: %__MODULE__{
            host: Ip.Host.t(),
            max: Hyper.Node.Net.id(),
            next: Hyper.Node.Net.id(),
            freed: [Hyper.Node.Net.id()],
            owners: %{reference() => Hyper.Node.Net.id()}
          }
  end

  @spec start_link(Ip.Host.t()) :: GenServer.on_start()
  def start_link(%Ip.Host{} = host) do
    GenServer.start_link(__MODULE__, host, name: __MODULE__)
  end

  @spec claim() :: {:ok, id()} | {:error, :exhausted}
  def claim, do: GenServer.call(__MODULE__, :claim)

  @spec release(id()) :: :ok
  def release(id), do: GenServer.cast(__MODULE__, {:release, id})

  @spec bind(id(), pid()) :: :ok
  def bind(id, owner), do: GenServer.call(__MODULE__, {:bind, id, owner})

  @spec lease(id()) :: Ip.Lease.t()
  def lease(id), do: GenServer.call(__MODULE__, {:lease, id})

  @impl true
  def init(%Ip.Host{} = host) do
    first..last//1 = Ip.net_ids(host)
    {:ok, %State{host: host, max: last, next: first}}
  end

  @impl true
  def handle_call(:claim, _from, %State{freed: [id | rest]} = state) do
    {:reply, {:ok, id}, %{state | freed: rest}}
  end

  def handle_call(:claim, _from, %State{next: next, max: max} = state) when next <= max do
    {:reply, {:ok, next}, %{state | next: next + 1}}
  end

  def handle_call(:claim, _from, %State{} = state) do
    {:reply, {:error, :exhausted}, state}
  end

  def handle_call({:bind, id, owner}, _from, %State{owners: owners} = state) do
    ref = Process.monitor(owner)
    {:reply, :ok, %{state | owners: Map.put(owners, ref, id)}}
  end

  def handle_call({:lease, id}, _from, %State{host: host} = state) do
    {:reply, Ip.lease(host, id), state}
  end

  @impl true
  def handle_cast({:release, id}, %State{freed: freed} = state) do
    {:noreply, %{state | freed: [id | freed]}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{owners: owners} = state) do
    case Map.pop(owners, ref) do
      {nil, _} -> {:noreply, state}
      {id, owners} -> {:noreply, %{state | owners: owners, freed: [id | state.freed]}}
    end
  end
end
