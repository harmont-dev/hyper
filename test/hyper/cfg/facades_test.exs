defmodule Hyper.Cfg.FacadesTest do
  use ExUnit.Case, async: false

  test "Cluster.topologies reads :libcluster app env" do
    assert is_list(Hyper.Cfg.Cluster.topologies())
  end
end
