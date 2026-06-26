defmodule Hyper.Cfg.Cluster do
  @moduledoc "Read-only view of the libcluster topology (`config :libcluster`)."

  @spec topologies :: keyword()
  def topologies, do: Application.get_env(:libcluster, :topologies, [])
end
