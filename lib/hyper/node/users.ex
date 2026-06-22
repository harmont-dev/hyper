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

      * `next` - the next never-allocated id (bump pointer), advanced up to `max`
      * `max`  - top of the configured range (inclusive)
      * `freed` - stack of returned ids available for reuse
      * `owners` - map of monitor references to bound ids

    The untouched tail of the range (`next..max`) is never materialised, so memory
    is O(ids handed out and returned), not O(range size).
    """
    @enforce_keys [:max, :next]
    defstruct [:max, :next, freed: [], owners: %{}]

    @type t :: %__MODULE__{
            max: Hyper.Node.Users.id(),
            next: Hyper.Node.Users.id(),
            freed: [Hyper.Node.Users.id()],
            owners: %{reference() => Hyper.Node.Users.id()}
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

  @doc "Allocate an id without auto-freeing. Pair with `release/1` or `bind/2`."
  @spec claim() :: {:ok, id()} | {:error, :exhausted}
  def claim, do: GenServer.call(__MODULE__, {:new})

  @doc "Return an id to the pool."
  @spec release(id()) :: :ok
  def release(id), do: GenServer.cast(__MODULE__, {:free, id})

  @doc "Free `id` automatically when `owner` dies."
  @spec bind(id(), pid()) :: :ok
  def bind(id, owner), do: GenServer.call(__MODULE__, {:bind, id, owner})

  @doc """
  Verify the configured uid/gid range is free, raising if anything occupies it.

  Run at node startup so we fail closed: handing out a uid that collides with an
  existing user would let a VM run as that user - a security hazard. Checks NSS
  users and groups (via `getent`) and the subordinate-id ranges in `/etc/subuid`
  and `/etc/subgid` for overlap with the configured range.
  """
  @spec test_system() :: :ok | {:error, term()}
  def test_system do
    alias Sys.Linux.Subid

    {min, max} = Hyper.Config.uid_gid_range()

    cond do
      passwd_conflicts(min, max) != [] ->
        {:error, :passwd_conflicts}

      group_conflicts(min, max) != [] ->
        {:error, :group_conflicts}

      subid_conflicts("subuid", Subid.subuid_ranges(), min, max) != [] ->
        {:error, :subuid_conflicts}

      subid_conflicts("subgid", Subid.subgid_ranges(), min, max) != [] ->
        {:error, :subgid_conflicts}

      true ->
        :ok
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
  def handle_call({:bind, id, owner}, _from, %State{owners: owners} = state) do
    ref = Process.monitor(owner)
    {:reply, :ok, %{state | owners: Map.put(owners, ref, id)}}
  end

  @impl true
  def handle_cast({:free, id}, %State{freed: freed} = state) do
    {:noreply, %{state | freed: [id | freed]}}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %State{owners: owners, freed: freed} = state
      ) do
    case Map.pop(owners, ref) do
      {nil, _} -> {:noreply, state}
      {id, owners} -> {:noreply, %{state | owners: owners, freed: [id | freed]}}
    end
  end

  # Passwd entries whose uid falls within [min, max].
  defp passwd_conflicts(min, max) do
    Sys.Linux.Nss.Passwd.entries()
    |> unwrap!("passwd")
    |> Enum.filter(&(&1.uid in min..max))
    |> Enum.map(&"passwd:#{&1.name}(#{&1.uid})")
  end

  # Group entries whose gid falls within [min, max].
  defp group_conflicts(min, max) do
    Sys.Linux.Nss.Group.entries()
    |> unwrap!("group")
    |> Enum.filter(&(&1.gid in min..max))
    |> Enum.map(&"group:#{&1.name}(#{&1.gid})")
  end

  # Subid ranges store an EXCLUSIVE max_id (start + count), so a range overlaps
  # the inclusive [min, max] iff min_id <= max and max_id > min.
  defp subid_conflicts(label, result, min, max) do
    case result do
      {:ok, ranges} ->
        ranges
        |> Enum.filter(fn r -> r.min_id <= max and r.max_id > min end)
        |> Enum.map(&"#{label}:#{&1.name}(#{&1.min_id}..#{&1.max_id})")

      # A missing subid file just means nothing is allocated.
      {:error, :enoent} ->
        []

      # Any other failure means we couldn't verify - fail closed.
      {:error, reason} ->
        raise "cannot read #{label} to verify uid/gid range: #{inspect(reason)}"
    end
  end

  defp unwrap!({:ok, value}, _label), do: value

  defp unwrap!({:error, reason}, label) do
    raise "cannot read #{label} to verify uid/gid range: #{inspect(reason)}"
  end
end
