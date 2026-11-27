defmodule Hyper.Cfg.VmLinuxTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.VmLinux

  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
  end

  test "maps the amd64/aarch64 doc keys to their arch atoms" do
    Toml.put_cache(%{"vmlinux" => %{"amd64" => "/k/amd64", "aarch64" => "/k/arm64"}})
    assert VmLinux.images() == %{x86_64: "/k/amd64", aarch64: "/k/arm64"}
  end

  test "omits an architecture that has no configured path" do
    assert VmLinux.images() == %{}

    Toml.put_cache(%{"vmlinux" => %{"amd64" => "/k/amd64"}})
    assert VmLinux.images() == %{x86_64: "/k/amd64"}
  end
end
