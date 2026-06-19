defmodule Hyper.Node.Img.Server do
  @moduledoc "GenServer responsible for managing a single mounted image."

  use GenServer

  defmodule State do
    @moduledoc false

    @type t :: %__MODULE__{}

    defstruct [:state]
  end

  defmodule Opts do
    @moduledoc "Options for starting an image server."

    @type t :: %__MODULE__{
            img_id: Hyper.Img.id()
          }
    defstruct [:img_id]
  end

  @doc "Create a new image server, which manages a single image on the current running node."
  @spec start_link(Opts.t()) :: GenServer.on_start()
  def start_link(%Opts{} = opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  @spec init(Opts.t()) :: {:ok, State.t()}
  def init(%Opts{} = opts) do
    {:ok, %State{}}
  end
end
