defmodule Hyper.Cfg.DirsTest do
  use ExUnit.Case, async: false

  alias Hyper.Cfg.Dirs
  alias Hyper.Cfg.Toml

  setup do
    Toml.put_cache(%{})
    on_exit(fn -> Toml.reload() end)
    :ok
  end

  test "work_dir defaults to /srv/hyper and every dir derives from it" do
    root = Dirs.work_dir()
    assert root == "/srv/hyper"

    assert Dirs.layer_dir() == Path.join(root, "layers")
    assert Dirs.socket_dir() == Path.join(root, "socks")
    assert Dirs.scratch_dir() == Path.join(root, "scratch")
    assert Dirs.chroot_base() == Path.join(root, "jails")
    assert Dirs.redist_dir() == Path.join(root, "redist")
  end

  test "redistributable install dirs nest under redist" do
    redist = Dirs.redist_dir()
    assert Dirs.vmlinux_install_dir() == Path.join(redist, "vmlinux")
    assert Dirs.umoci_install_dir() == Path.join(redist, "umoci")
    assert Dirs.firecracker_install_dir() == Path.join(redist, "firecracker")
  end

  test "work_dir follows the config.toml value and dirs re-derive" do
    Toml.put_cache(%{"work_dir" => "/data/hyper"})
    assert Dirs.work_dir() == "/data/hyper"
    assert Dirs.layer_dir() == "/data/hyper/layers"
    assert Dirs.firecracker_install_dir() == "/data/hyper/redist/firecracker"
  end
end
