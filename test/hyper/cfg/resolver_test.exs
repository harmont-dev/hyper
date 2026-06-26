defmodule Hyper.Cfg.ResolverTest do
  use ExUnit.Case, async: false

  import Hyper.Cfg, only: [get_cfg: 1]

  setup do
    on_exit(fn -> Application.delete_env(:hyper, :__cfg_test) end)
  end

  test "list order is priority: runtime wins over toml wins over default" do
    Application.put_env(:hyper, :__cfg_test, "from_runtime")

    assert get_cfg(runtime: :__cfg_test, toml: "nope", default: "d") == "from_runtime"
  end

  test "falls through absent runtime to the default" do
    Application.delete_env(:hyper, :__cfg_test)

    assert get_cfg(runtime: :__cfg_test, default: "d") == "d"
  end

  test "nested {mod, key} runtime source reads a keyword under the module env" do
    Application.put_env(:hyper, __MODULE__, foo: "bar")

    assert get_cfg(runtime: {__MODULE__, :foo}, default: "d") == "bar"
    assert get_cfg(runtime: {__MODULE__, :absent}, default: "d") == "d"
  after
    Application.delete_env(:hyper, __MODULE__)
  end

  test "a required key (no default) with every source absent raises a named error" do
    assert_raise Hyper.Cfg.MissingError, ~r/required/, fn ->
      get_cfg(toml: "definitely.absent")
    end
  end
end
