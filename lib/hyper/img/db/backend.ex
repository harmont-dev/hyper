defmodule Hyper.Img.Db.Backend do
  @moduledoc """
  Resolves the active image-graph storage backend from configuration.

  Configured via `config :hyper, Hyper.Img.Db, backend: :postgres | :sqlite`.
  `:postgres` is the cluster-safe default; `:sqlite` is valid only on a
  single node (see `Hyper.Img.Db.SingleNodeGuard`).
  """

  @repos %{
    postgres: Hyper.Img.Db.Repo.Postgres,
    sqlite: Hyper.Img.Db.Repo.Sqlite
  }

  @doc "The configured backend, defaulting to `:postgres`."
  @spec selected() :: :postgres | :sqlite
  def selected do
    :hyper
    |> Application.get_env(Hyper.Img.Db, [])
    |> Keyword.get(:backend, :postgres)
  end

  @doc "The concrete repo module for the configured backend."
  @spec repo() :: module()
  def repo, do: Map.fetch!(@repos, selected())

  @doc "True when the SQLite backend is configured."
  @spec sqlite?() :: boolean()
  def sqlite?, do: selected() == :sqlite
end
