defmodule Hyper.Node.Layer.Server do
  @moduledoc "GenServer responsible for managing a single mounted layer."

  use GenServer
  require Logger

  alias Hyper.Node.Layer.Repo
  alias Hyper.Sys.Linux.Losetup

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            blk_path: Path.t()
          }

    defstruct [:blk_path]
  end

  defmodule Opts do
    @moduledoc false

    @type t :: %__MODULE__{
            layer_id: Hyper.Layer.id()
          }

    defstruct [:layer_id]
  end

  @doc "Get the block device path of the layer managed by `server`."
  @spec blk_path(GenServer.server()) :: Path.t()
  def blk_path(server), do: GenServer.call(server, :blk_path)

  @doc "Create a new layer, mounting it as a block device."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{layer_id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via(layer_id))
  end

  @impl true
  def init(%Opts{layer_id: layer_id}) do
    Process.flag(:trap_exit, true)

    with {:ok, layer_path} <- Repo.find_layer(layer_id),
         {:ok, blk_path} <- Losetup.mount_ro(layer_path) do
      {:ok, %State{blk_path: blk_path}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:blk_path, _from, %State{blk_path: blk_path} = state) do
    {:reply, blk_path, state}
  end

  @impl true
  def terminate(_reason, %State{blk_path: blk_path}) do
    case Losetup.umount(blk_path) do
      {:ok, _path} ->
        :ok

      {:error, {errc, out}} ->
        Logger.error("Failed to unmount layer block device #{blk_path} (exit #{errc}): #{out}")
        :ok
    end
  end

  @spec via(Hyper.Layer.id()) :: term()
  defp via(layer_id) do
    {:via, Registry, {Hyper.Node.Layer.registry()}}
  end
end
