defmodule Hyper.Node.Img.Supervisor do
  @moduledoc """
  Owns this node's `Hyper.Node.Img.Server` processes — one per mounted image,
  started on demand and torn down independently.
  """

  use DynamicSupervisor

  alias Hyper.Node.Img.Server

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Start an image server under this supervisor."
  @spec start_server(term()) :: DynamicSupervisor.on_start_child()
  def start_server(opts) do
    DynamicSupervisor.start_child(__MODULE__, {Server, opts})
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
