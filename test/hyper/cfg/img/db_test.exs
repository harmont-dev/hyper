defmodule Hyper.Cfg.Img.DbTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Img.Db
  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
  end

  test "repo_opts carries exactly the connection keys set in [img.db]" do
    rows = [
      {%{}, []},
      {%{"img" => %{"store" => "/mnt/layers"}}, []},
      {%{"img" => %{"db" => %{"hostname" => "db.internal"}}}, [hostname: "db.internal"]},
      {%{"img" => %{"db" => %{"database" => "hyper", "username" => "hyper", "pool" => 3}}},
       [database: "hyper", username: "hyper"]}
    ]

    for {toml, expected} <- rows do
      Toml.put_cache(toml)
      assert Db.repo_opts() == expected, inspect(toml)
    end
  end

  test "a password in [img.db] refuses to load" do
    Toml.put_cache(%{"img" => %{"db" => %{"hostname" => "db.internal", "password" => "hunter2"}}})

    assert_raise ArgumentError, ~r/HYPER_DB_PASSWORD/, fn -> Db.repo_opts() end
  end
end
