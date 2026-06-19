defmodule Hyper.Node.Img.Writable do
  @moduledoc """
  A single VM's writable view of an image. Activates the image (`Img.Server`),
  takes a reference on it, and layers a writable transient dm-snapshot — backed by
  a per-VM sparse scratch COW — on top of the image's read-only composed device.
  `blk_path/1` is the read-write device the VM boots from.

  Top of the three-tier hold chain: this holds the `Img.Server` (which holds its
  `Layer.Server`s). When this stops or crashes, its `:DOWN` releases the image,
  and `terminate/2` tears down the writable device, loop, and scratch file. The
  reference release is automatic (monitor); only the local devices need cleanup.
  """

  use GenServer
  require Logger

  alias Hyper.Node.Img
  alias Hyper.Sys.Linux.Dmsetup
  alias Hyper.Sys.Linux.Losetup

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id(),
            vm_id: Hyper.Vm.id(),
            img_server: pid(),
            cow_path: Path.t(),
            cow_loop: Path.t(),
            dm_name: String.t(),
            blk_path: Path.t()
          }

    defstruct [:img_id, :vm_id, :img_server, :cow_path, :cow_loop, :dm_name, :blk_path]
  end

  defmodule Opts do
    @moduledoc "Options for starting a writable image layer."

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id(),
            vm_id: Hyper.Vm.id()
          }

    defstruct [:img_id, :vm_id]
  end

  @doc "The read-write block device the VM boots from."
  @spec blk_path(GenServer.server()) :: Path.t()
  def blk_path(server), do: GenServer.call(server, :blk_path)

  @doc "Start a writable layer for `opts`."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(%Opts{img_id: img_id, vm_id: vm_id}) do
    Process.flag(:trap_exit, true)

    with {:ok, img_pid} <- Img.activate(img_id),
         :ok <- Img.Server.acquire(img_pid),
         {:ok, state} <- assemble(img_id, vm_id, img_pid) do
      {:ok, state}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:blk_path, _from, %State{blk_path: blk_path} = state) do
    {:reply, blk_path, state}
  end

  @impl true
  def terminate(_reason, %State{} = state) do
    _ = remove_dm(state.dm_name)
    _ = detach_loop(state.cow_loop)
    _ = File.rm(state.cow_path)
    # The Img.Server reference is released automatically: it monitors us, so our
    # exit produces the :DOWN that drops the hold.
    :ok
  end

  # Build the writable device on top of the image's composed read-only device,
  # cleaning up partial resources if a later step fails.
  @spec assemble(Hyper.Img.id(), Hyper.Vm.id(), pid()) :: {:ok, State.t()} | {:error, term()}
  defp assemble(img_id, vm_id, img_pid) do
    origin = Img.Server.blk_path(img_pid)
    name = dm_name(vm_id)

    with {:ok, sectors} <- Dmsetup.device_sectors(origin),
         {:ok, cow_path} <- create_scratch(vm_id, sectors),
         {:ok, cow_loop} <- mount_rw(cow_path),
         {:ok, blk_path} <- create_writable(name, origin, cow_loop, sectors, cow_path) do
      {:ok,
       %State{
         img_id: img_id,
         vm_id: vm_id,
         img_server: img_pid,
         cow_path: cow_path,
         cow_loop: cow_loop,
         dm_name: name,
         blk_path: blk_path
       }}
    end
  end

  @spec mount_rw(Path.t()) :: {:ok, Path.t()} | {:error, term()}
  defp mount_rw(cow_path) do
    case Losetup.mount_rw(cow_path) do
      {:ok, loop} ->
        {:ok, loop}

      {:error, _} = err ->
        _ = File.rm(cow_path)
        err
    end
  end

  @spec create_writable(String.t(), Path.t(), Path.t(), pos_integer(), Path.t()) ::
          {:ok, Path.t()} | {:error, term()}
  defp create_writable(name, origin, cow_loop, sectors, cow_path) do
    case Dmsetup.create_writable(name, origin, cow_loop, sectors) do
      {:ok, blk} ->
        {:ok, blk}

      {:error, _} = err ->
        _ = detach_loop(cow_loop)
        _ = File.rm(cow_path)
        err
    end
  end

  # Create a sparse COW file sized to the image, to hold the snapshot's exceptions.
  @spec create_scratch(Hyper.Vm.id(), pos_integer()) :: {:ok, Path.t()} | {:error, term()}
  defp create_scratch(vm_id, sectors) do
    path = Path.join(Hyper.Config.scratch_dir(), "cow-#{sanitize(vm_id)}.img")

    case create_sparse(path, sectors * 512) do
      :ok -> {:ok, path}
      {:error, reason} -> {:error, {:scratch_create_failed, reason}}
    end
  end

  @spec create_sparse(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  defp create_sparse(path, bytes) do
    case File.open(path, [:write, :raw]) do
      {:ok, fd} ->
        result = with {:ok, _} <- :file.position(fd, bytes), do: :file.truncate(fd)
        _ = File.close(fd)
        result

      {:error, _} = err ->
        err
    end
  end

  @spec remove_dm(String.t()) :: :ok
  defp remove_dm(name) do
    case Dmsetup.remove(name) do
      :ok ->
        :ok

      {:error, {errc, out}} ->
        Logger.error("Failed to remove dm device #{name} (exit #{errc}): #{out}")
    end

    :ok
  end

  @spec detach_loop(Path.t()) :: :ok
  defp detach_loop(loop) do
    case Losetup.umount(loop) do
      {:ok, _} ->
        :ok

      {:error, {errc, out}} ->
        Logger.error("Failed to detach loop #{loop} (exit #{errc}): #{out}")
    end

    :ok
  end

  @spec dm_name(Hyper.Vm.id()) :: String.t()
  defp dm_name(vm_id), do: "hyper-wr-#{sanitize(vm_id)}"

  @spec sanitize(String.t()) :: String.t()
  defp sanitize(id), do: String.replace(id, ~r/[^A-Za-z0-9._-]/, "_")
end
