defmodule Hyper.ConfigTest do
  use ExUnit.Case, async: true

  alias Hyper.Config

  test "all firecracker paths are derived from work_dir" do
    wd = Config.work_dir()

    assert Config.redist_dir() == Path.join(wd, "redist")
    assert Config.firecracker_install_dir() == Path.join([wd, "redist", "firecracker"])
    assert Config.firecracker_bin() == Path.join([wd, "redist", "firecracker", "firecracker"])
    assert Config.jailer_bin() == Path.join([wd, "redist", "firecracker", "jailer"])
    assert Config.chroot_base() == Path.join(wd, "jails")
    assert Config.socket_dir() == Path.join(wd, "socks")
    assert Config.scratch_dir() == Path.join(wd, "scratch")
  end

  test "the firecracker binary basename is stable" do
    assert Path.basename(Config.firecracker_bin()) == "firecracker"
    assert Path.basename(Config.jailer_bin()) == "jailer"
  end
end
