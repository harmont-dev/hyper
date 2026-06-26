defmodule Hyper.Cfg.VmlinuxTest do
  use ExUnit.Case, async: false

  test "images/0 defaults to an empty map and reads config :hyper, :vmlinux" do
    Application.delete_env(:hyper, :vmlinux)
    assert Hyper.Cfg.Vmlinux.images() == %{}

    Application.put_env(:hyper, :vmlinux, %{x86_64: "/k/vmlinux"})
    assert Hyper.Cfg.Vmlinux.images() == %{x86_64: "/k/vmlinux"}
  after
    Application.delete_env(:hyper, :vmlinux)
  end
end
