defmodule Hyper.Cfg.FacadesTest do
  use ExUnit.Case, async: false

  test "Cluster.topologies reads :libcluster app env" do
    assert is_list(Hyper.Cfg.Cluster.topologies())
  end

  test "Db.repo_opts reads the Ecto repo config" do
    assert Keyword.keyword?(Hyper.Cfg.Db.repo_opts())
  end
end
