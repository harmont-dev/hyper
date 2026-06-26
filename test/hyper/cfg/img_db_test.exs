defmodule Hyper.Cfg.Img.DbTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Img.Db

  setup do
    on_exit(fn -> Application.delete_env(:hyper, Db) end)
    :ok
  end

  test "repo_opts is empty when unset" do
    Application.delete_env(:hyper, Db)
    assert Db.repo_opts() == []
  end

  test "returns only the set keys" do
    Application.put_env(:hyper, Db, database: "prod", hostname: "db.internal")
    opts = Db.repo_opts()
    assert opts[:database] == "prod"
    assert opts[:hostname] == "db.internal"
    refute Keyword.has_key?(opts, :username)
  end
end
