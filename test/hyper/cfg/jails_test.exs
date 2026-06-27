defmodule Hyper.Cfg.JailsTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Jails
  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
    :ok
  end

  test "uid_gid_range is required: raises when [jails] omits it" do
    assert_raise Hyper.Cfg.MissingError, fn -> Jails.uid_gid_range() end
  end

  test "uid_gid_range parses [min, max] integers and refuses anything else" do
    Toml.put_cache(%{"jails" => %{"uid_gid_range" => [800_000, 899_999]}})
    assert Jails.uid_gid_range() == {800_000, 899_999}

    # A non-integer pair must raise, never yield a bogus confinement band.
    Toml.put_cache(%{"jails" => %{"uid_gid_range" => ["a", "b"]}})
    assert_raise ArgumentError, fn -> Jails.uid_gid_range() end
  end
end
