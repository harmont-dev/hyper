defmodule Hyper.Cfg.TomlTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Toml

  setup do
    on_exit(fn -> Toml.reload() end)
    :ok
  end

  test "fetch_in/2 traverses nested tables and stops at a missing segment" do
    cfg = %{"tools" => %{"firecracker" => "/opt/fc"}}
    assert Toml.fetch_in(cfg, "tools.firecracker") == {:ok, "/opt/fc"}
    assert Toml.fetch_in(cfg, "tools.jailer") == :error
    assert Toml.fetch_in(cfg, "tools.firecracker.extra") == :error
    assert Toml.fetch_in(cfg, "missing") == :error
  end

  test "fetch/1 reads the seeded cache; absent keys return :error" do
    Toml.put_cache(%{"work_dir" => "/data", "tools" => %{"firecracker" => "/opt/fc"}})
    assert Toml.fetch("work_dir") == {:ok, "/data"}
    assert Toml.fetch("tools.firecracker") == {:ok, "/opt/fc"}
    assert Toml.fetch("tools.jailer") == :error

    Toml.put_cache(%{})
    assert Toml.fetch("work_dir") == :error
  end
end
