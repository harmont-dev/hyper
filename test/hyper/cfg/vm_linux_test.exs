defmodule Hyper.Cfg.VmLinuxTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.VmLinux
  alias Hyper.Cfg.Toml

  setup do
    Application.delete_env(:hyper, VmLinux)
    Toml.put_cache(%{})
    on_exit(fn ->
      Application.delete_env(:hyper, VmLinux)
      Toml.reload()
    end)
    :ok
  end

  test "empty by default" do
    assert VmLinux.images() == %{}
  end

  test "maps amd64/aarch64 keys to arch atoms from config.exs" do
    Application.put_env(:hyper, VmLinux, amd64: "/k/amd64", aarch64: "/k/arm64")
    assert VmLinux.images() == %{x86_64: "/k/amd64", aarch64: "/k/arm64"}
  end

  test "reads from [vmlinux] toml; config.exs wins per key" do
    Toml.put_cache(%{"vmlinux" => %{"amd64" => "/toml/amd64", "aarch64" => "/toml/arm64"}})
    Application.put_env(:hyper, VmLinux, amd64: "/exs/amd64")
    assert VmLinux.images() == %{x86_64: "/exs/amd64", aarch64: "/toml/arm64"}
  end
end
