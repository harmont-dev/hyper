defmodule Hyper.Cfg.TomlTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Toml

  setup do
    on_exit(fn -> Toml.reload() end)
    :ok
  end

  @cfg %{"work_dir" => "/data", "tools" => %{"firecracker" => "/opt/fc"}}

  for {path, expected} <- [
        {"work_dir", {:ok, "/data"}},
        {"tools.firecracker", {:ok, "/opt/fc"}},
        {"tools.jailer", :error},
        {"tools.firecracker.extra", :error},
        {"missing", :error}
      ] do
    test "fetch_in #{inspect(path)} -> #{inspect(expected)}" do
      assert Toml.fetch_in(unquote(Macro.escape(@cfg)), unquote(path)) ==
               unquote(Macro.escape(expected))
    end
  end

  test "fetch/1 reads the seeded cache; absent keys return :error" do
    Toml.put_cache(@cfg)
    assert Toml.fetch("work_dir") == {:ok, "/data"}
    assert Toml.fetch("tools.firecracker") == {:ok, "/opt/fc"}
    assert Toml.fetch("tools.jailer") == :error

    Toml.put_cache(%{})
    assert Toml.fetch("work_dir") == :error
  end
end
