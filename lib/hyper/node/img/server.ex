defmodule Hyper.Node.Img.Server do
  @moduledoc """
  GenServer representing a single active image on this node. Registered by image
  id and holds the ordered layer set the image resolves to, so the node can be
  asked which active images depend on a given layer.

  On start it acquires a reference on each of its layers' `Layer.Server`s, keeping
  them mounted for as long as this image is active. Because the acquire is a
  process monitor, the layers are released automatically when this server stops
  or crashes — no explicit teardown.
  """

  use GenServer

  alias Hyper.Img.Db
  alias Hyper.Node.Layer

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id(),
            layers: [Hyper.Layer.id()]
          }

    defstruct [:img_id, :layers]
  end

  defmodule Opts do
    @moduledoc "Options for starting an image server."

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id()
          }

    defstruct [:img_id]
  end

  @doc "The ordered layer ids that compose the image managed by `server`."
  @spec layers(GenServer.server()) :: [Hyper.Layer.id()]
  def layers(server), do: GenServer.call(server, :layers)

  @doc "Start an image server for `opts`, registered by image id."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{img_id: img_id} = opts) do
    GenServer.start_link(__MODULE__, opts, name: via(img_id))
  end

  @impl true
  def init(%Opts{img_id: img_id}) do
    layers = resolve_layers(img_id)

    case acquire_layers(layers) do
      :ok -> {:ok, %State{img_id: img_id, layers: layers}}
      {:error, reason} -> {:stop, reason}
    end
  end

  # The ordered layer ids that compose `img_id`, from the image-lineage database.
  @spec resolve_layers(Hyper.Img.id()) :: [Hyper.Layer.id()]
  defp resolve_layers(img_id) do
    img_id
    |> Db.Image.resolve_chain()
    |> Enum.map(& &1.id)
  end

  # Mount-or-reuse each layer and take a reference on it. Stops at the first
  # failure; any layers already acquired are released when this process exits.
  @spec acquire_layers([Hyper.Layer.id()]) :: :ok | {:error, term()}
  defp acquire_layers(layers) do
    Enum.reduce_while(layers, :ok, fn layer_id, :ok ->
      with {:ok, pid} <- Layer.Server.for_layer(layer_id),
           :ok <- Layer.Server.acquire(pid) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def handle_call(:layers, _from, %State{layers: layers} = state) do
    {:reply, layers, state}
  end

  @spec via(Hyper.Img.id()) :: GenServer.name()
  defp via(img_id), do: {:via, Registry, {Hyper.Node.Img.registry(), img_id}}
end
