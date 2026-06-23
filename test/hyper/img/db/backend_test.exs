defmodule Hyper.Img.Db.BackendTest do
  use ExUnit.Case, async: false

  alias Hyper.Img.Db.Backend

  setup do
    original = Application.get_env(:hyper, Hyper.Img.Db)
    on_exit(fn -> Application.put_env(:hyper, Hyper.Img.Db, original) end)
    :ok
  end

  test "defaults to the Postgres repo" do
    Application.put_env(:hyper, Hyper.Img.Db, [])
    assert Backend.selected() == :postgres
    assert Backend.repo() == Hyper.Img.Db.Repo.Postgres
    refute Backend.sqlite?()
  end

  test "resolves the SQLite repo when configured" do
    Application.put_env(:hyper, Hyper.Img.Db, backend: :sqlite)
    assert Backend.selected() == :sqlite
    assert Backend.repo() == Hyper.Img.Db.Repo.Sqlite
    assert Backend.sqlite?()
  end
end
