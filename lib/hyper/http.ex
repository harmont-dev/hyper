defmodule Hyper.Http do
  @moduledoc """
    Public Http Interface to a Hyper Cluster
  """

  alias Hyper.Cfg.Http, as: Config

  @doc """
  The Http Server's Supervisor child, or `[]` when the server is diabled i.e. the default.
  Spliced into the application's supervision tree at boot.
  """
  @spec server_children :: [{module(), keyword()}]
  def server_children do
    config = Config.load()

    if config.enabled do
      [{Plug.Cowboy, Config.server_options(config)}]
    else
      []
    end
  end
end
