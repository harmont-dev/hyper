defmodule Hyper.Img.Db.Config do
  @moduledoc """
  Single place to configure the image-graph database.

  Choose the backend in your config:

      # cluster-safe default
      config :hyper, Hyper.Img.Db, backend: :postgres

      # single-node deployments only
      config :hyper, Hyper.Img.Db, backend: :sqlite

  The backend is resolved at compile time (the Ecto adapter is fixed when
  `Hyper.Img.Db.Repo` is compiled), so changing it takes effect on the next
  build. Connection settings live under `config :hyper, Hyper.Img.Db.Repo`.
  """

  @backend Application.compile_env(:hyper, [Hyper.Img.Db, :backend], :postgres)

  @adapters %{
    postgres: Ecto.Adapters.Postgres,
    sqlite: Ecto.Adapters.SQLite3
  }

  @doc "The configured backend (`:postgres` | `:sqlite`)."
  @spec backend() :: :postgres | :sqlite
  def backend, do: @backend

  @doc "The Ecto adapter module for the configured backend."
  @spec adapter() :: module()
  def adapter, do: Map.fetch!(@adapters, @backend)

  @doc "True when the SQLite backend is configured (single-node only)."
  @spec sqlite?() :: boolean()
  def sqlite?, do: @backend == :sqlite
end
