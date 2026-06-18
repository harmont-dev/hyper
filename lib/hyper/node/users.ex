defmodule Hyper.Node.Users do
  @moduledoc """
  Process running on the `Hyper.Node` responsible for creating and managing POSIX users.

  The reason we need this is that Firecracker prefers that each new virtual machine we create is
  managed with a unique user. Each said user needs access to /dev/kvm.

  To solve this problem, `Hyper.Node.Users` mints user ids under the configured group.
  """

  use GenServer

  @typedoc "A uid/gid."
  @type id :: integer()

  defmodule State do
    @moduledoc """
    Bump-pointer + freed-stack id pool. Only ids currently in flight are stored:

      * `next` — the next never-allocated id (bump pointer), advanced up to `max`
      * `max`  — top of the configured range (inclusive)
      * `freed` — stack of returned ids available for reuse

    The untouched tail of the range (`next..max`) is never materialised, so memory
    is O(ids handed out and returned), not O(range size).
    """
    @enforce_keys [:max, :next]
    defstruct [:max, :next, freed: []]

    @type t :: %__MODULE__{
            max: Hyper.Node.Users.id(),
            next: Hyper.Node.Users.id(),
            freed: [Hyper.Node.Users.id()]
          }
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Run the given callable with a new UID, freeing it afterward."
  @spec with_id((id() -> result)) :: result | {:error, :exhausted} when result: var
  def with_id(fun) when is_function(fun, 1) do
    with {:ok, id} <- GenServer.call(__MODULE__, {:new}) do
      try do
        fun.(id)
      after
        GenServer.cast(__MODULE__, {:free, id})
      end
    end
  end

  @impl true
  def init(_opts) do
    {min, max} = Hyper.Config.uid_gid_range()
    {:ok, %State{max: max, next: min}}
  end

  @impl true
  def handle_call({:new}, _from, %State{freed: [id | rest]} = state) do
    {:reply, {:ok, id}, %{state | freed: rest}}
  end

  @impl true
  def handle_call({:new}, _from, %State{next: next, max: max} = state) when next <= max do
    {:reply, {:ok, next}, %{state | next: next + 1}}
  end

  @impl true
  def handle_call({:new}, _from, %State{} = state) do
    {:reply, {:error, :exhausted}, state}
  end

  @impl true
  def handle_cast({:free, id}, %State{freed: freed} = state) do
    {:noreply, %{state | freed: [id | freed]}}
  end
end
