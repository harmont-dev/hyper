defmodule Hyper.Cfg.Db do
  @moduledoc "Read-only view of the image-DB Ecto repo config."

  @spec repo_opts :: keyword()
  def repo_opts, do: Application.get_env(:hyper, Hyper.Img.Db.Repo, [])
end
