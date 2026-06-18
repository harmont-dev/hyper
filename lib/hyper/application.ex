defmodule Hyper.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # :opentelemetry starts as its own OTP application (a dependency of :hyper),
    # so it is already running before this supervisor boots.
    children = [
      # This machine's participation in the cluster: owns the cluster-wide VM
      # registry and the local supervisor that runs this node's microVMs.
      Hyper.Node
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Hyper.Supervisor)
  end
end
