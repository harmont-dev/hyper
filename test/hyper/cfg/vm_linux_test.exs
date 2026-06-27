defmodule Hyper.Cfg.VmLinuxTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.VmLinux

  setup do
    Application.delete_env(:hyper, VmLinux)
    Hyper.Cfg.Toml.put_cache(%{})

    on_exit(fn ->
      Application.delete_env(:hyper, VmLinux)
      Hyper.Cfg.Toml.reload()
    end)

    :ok
  end

  test "maps the amd64/aarch64 doc keys to their arch atoms" do
    Application.put_env(:hyper, VmLinux, amd64: "/k/amd64", aarch64: "/k/arm64")
    assert VmLinux.images() == %{x86_64: "/k/amd64", aarch64: "/k/arm64"}
  end

  test "omits an architecture that has no configured path" do
    assert VmLinux.images() == %{}

    Application.put_env(:hyper, VmLinux, amd64: "/k/amd64")
    assert VmLinux.images() == %{x86_64: "/k/amd64"}
  end
end
