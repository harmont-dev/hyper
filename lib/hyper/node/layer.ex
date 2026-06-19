defmodule Hyper.Node.Layer do
  @moduledoc """
  Supervisor for this node's mounted layers. Owns a unique `Registry`
  (`layer_id -> Layer.Server`) and a `DynamicSupervisor` that holds those
  servers, so a layer can be mounted on demand and looked up by its id.
  """
  use Supervisor

  alias Hyper.Node.Layer.Server

  @registry Hyper.Node.Layer.Registry
  @server_sup Hyper.Node.Layer.Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @server_sup}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc false
  def registry, do: @registry

  @doc "Mount `layer_id` on this node (or reuse the server already mounting it)."
  @spec start_server(Hyper.Layer.id()) :: {:ok, pid()} | {:error, term()}
  def start_server(layer_id) do
    case DynamicSupervisor.start_child(@server_sup, {Server, %Server.Opts{layer_id: layer_id}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _} = err -> err
    end
  end

  @doc "Every layer id currently mounted on this node."
  @spec active() :: [Hyper.Layer.id()]
  def active do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
