defmodule Hyper.Node.Layer do
  @moduledoc """
  Supervisor which manages all active `Layer.Server`s and allows you to look them up by the layer
  key.

  Contains a registry of children processes, as well as 
  """
  use Supervisor

  @registry Hyper.Node.Layer.Registry
  @image_sup Hyper.Node.Layer.Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @image_sup}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
