defmodule Hyper.Cfg.Img.Db do
  @moduledoc """
  Image-database (Ecto/Postgres) connection settings — `database`/`username`/
  `password`/`hostname`. These are secrets, so they are read from `config.exs`
  only (`config :hyper, Hyper.Cfg.Img.Db, ...`), never the shared `config.toml`.
  `Hyper.Img.Db.Repo` merges these over its compile-time defaults at init.
  """

  import Hyper.Cfg, only: [get_cfg: 1]

  @keys [:database, :username, :hostname]

  @doc "Operator-set repo options (only the keys actually set), for `Repo.init/2`."
  @spec repo_opts :: keyword()
  def repo_opts, do: opts(get_cfg(toml: "img.db", default: %{}))

  @spec opts(map()) :: keyword()
  defp opts(%{"password" => _}) do
    raise ArgumentError,
          "[img.db] password is not read from the world-readable config.toml; " <>
            "set HYPER_DB_PASSWORD in the node's environment instead"
  end

  defp opts(table) do
    for key <- @keys, {:ok, value} <- [Map.fetch(table, Atom.to_string(key))], do: {key, value}
  end
end
