defmodule Hyper.Cfg.Img.Db do
  @moduledoc """
  Image-database (Ecto/Postgres) connection settings — `database`/`username`/
  `password`/`hostname`. These are secrets, so they are read from `config.exs`
  only (`config :hyper, Hyper.Cfg.Img.Db, ...`), never the shared `config.toml`.
  `Hyper.Img.Db.Repo.init/2` merges these over its compile-time defaults.
  """

  @keys [:database, :username, :password, :hostname]

  @doc "Operator-set repo options (only the keys actually set), for `Repo.init/2`."
  @spec repo_opts :: keyword()
  def repo_opts do
    env = Application.get_env(:hyper, __MODULE__, [])
    Enum.filter(env, fn {k, _} -> k in @keys end)
  end
end
