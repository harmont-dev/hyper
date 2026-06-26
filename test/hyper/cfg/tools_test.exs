defmodule Hyper.Cfg.ToolsTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Toml
  alias Hyper.Cfg.Tools

  setup do
    # Hermetic: empty TOML cache so we assert built-in defaults, not the
    # ambient /etc/hyper/config.toml. Restore the real cache afterward.
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
    :ok
  end

  test "privileged tools with no config.toml fall back to their sbin defaults" do
    assert Tools.dmsetup() == "/usr/sbin/dmsetup"
    assert Tools.losetup() == "/usr/sbin/losetup"
    assert Tools.blockdev() == "/usr/sbin/blockdev"
  end

  test "privileged tool paths come only from the [tools] table" do
    Toml.put_cache(%{"tools" => %{"dmsetup" => "/custom/dmsetup"}})
    assert Tools.dmsetup() == "/custom/dmsetup"
  end

  test "node tools default to bare PATH names / known install path" do
    assert Tools.skopeo() == "skopeo"
    assert Tools.mke2fs() == "mke2fs"
    assert Tools.suidhelper() == "/usr/local/bin/hyper-suidhelper"
    assert Tools.umoci() == nil
  end

  test "node tools: config.exs (runtime) overrides config.toml" do
    Toml.put_cache(%{"tools" => %{"skopeo" => "/from/toml"}})
    assert Tools.skopeo() == "/from/toml"

    Application.put_env(:hyper, Tools, skopeo: "/from/exs")
    assert Tools.skopeo() == "/from/exs"
  after
    Application.delete_env(:hyper, Tools)
  end

  test "required tools raise (non-raising form returns :error) when unset" do
    assert Tools.firecracker_configured() == :error
    assert Tools.jailer_configured() == :error
    assert_raise Hyper.Cfg.MissingError, fn -> Tools.firecracker() end
    assert_raise Hyper.Cfg.MissingError, fn -> Tools.jailer() end
  end
end
