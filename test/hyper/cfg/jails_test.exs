defmodule Hyper.Cfg.JailsTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Jails
  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
    :ok
  end

  test "defaults match the helper's compiled-in defaults" do
    assert Jails.cgroup() == "hyper"
    assert Jails.uid_gid_range() == {900_000, 999_999}
  end

  test "reads the [jails] table when present" do
    Toml.put_cache(%{"jails" => %{"cgroup" => "fleet", "uid_gid_range" => [800_000, 899_999]}})
    assert Jails.cgroup() == "fleet"
    assert Jails.uid_gid_range() == {800_000, 899_999}
  end

  test "uid_gid_range parses a TOML [min, max] array into a tuple" do
    assert Jails.range_from([800_000, 899_999]) == {800_000, 899_999}
    assert Jails.range_from(nil) == {900_000, 999_999}
    assert Jails.range_from("garbage") == {900_000, 999_999}
    # A two-element list of non-integers must fall to the default, never a bogus tuple.
    assert Jails.range_from(["a", "b"]) == {900_000, 999_999}
  end
end
