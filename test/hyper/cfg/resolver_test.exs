defmodule Hyper.Cfg.ResolverTest do
  use ExUnit.Case, async: false

  import Hyper.Cfg, only: [get_cfg: 1]

  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{"present" => "from_toml"})
    on_exit(fn -> Toml.reload() end)
  end

  test "list order is priority: toml wins over default" do
    assert get_cfg(toml: "present", default: "d") == "from_toml"
  end

  test "falls through absent toml to the default" do
    assert get_cfg(toml: "absent", default: "d") == "d"
  end

  test "a required key (no default) with every source absent raises a named error" do
    assert_raise Hyper.Cfg.MissingError, ~r/required/, fn ->
      get_cfg(toml: "definitely.absent")
    end
  end

  test "fetch_cfg/1 returns {:ok, value} or :error without raising" do
    assert Hyper.Cfg.fetch_cfg(toml: "present") == {:ok, "from_toml"}
    assert Hyper.Cfg.fetch_cfg(toml: "definitely.absent") == :error
    assert Hyper.Cfg.fetch_cfg(toml: "definitely.absent", default: "d") == {:ok, "d"}
  end
end
