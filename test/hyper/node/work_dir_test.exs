defmodule Hyper.Node.WorkDirTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Hyper.Cfg.Dirs
  alias Hyper.Node.WorkDir

  setup do
    original = Hyper.Cfg.Toml.reload()
    tmp = Path.join(System.tmp_dir!(), "hyper-work-dir-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Hyper.Cfg.Toml.put_cache(Map.put(original, "work_dir", tmp))

    on_exit(fn ->
      Hyper.Cfg.Toml.put_cache(original)
      File.rm_rf!(tmp)
    end)

    :ok
  end

  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o7777)

  defp write!(path, mode) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "guest data")
    File.chmod!(path, mode)
    path
  end

  test "an install left to the umask is tightened to 0700 dirs and 0600 data files" do
    for dir <- [Dirs.work_dir(), Dirs.layer_dir(), Dirs.scratch_dir()] do
      File.mkdir_p!(dir)
      File.chmod!(dir, 0o775)
    end

    data = [
      write!(Path.join(Dirs.scratch_dir(), "thinpool.data"), 0o664),
      write!(Path.join(Dirs.scratch_dir(), "fork-delta-v1.img"), 0o644),
      write!(Path.join(Dirs.layer_dir(), "layer_abc.img"), 0o664),
      write!(Path.join(Dirs.layer_dir(), ".incoming-1.img"), 0o604)
    ]

    log = capture_log(fn -> assert WorkDir.secure() == :ok end)

    private = [Dirs.work_dir(), Dirs.layer_dir(), Dirs.scratch_dir(), Dirs.redist_dir()]

    for dir <- [Dirs.chroot_base() | private] do
      assert mode(dir) == 0o700, dir
    end

    for path <- data do
      assert mode(path) == 0o600, path
      assert File.read!(path) == "guest data"
      assert log =~ path
    end

    assert capture_log(fn -> assert WorkDir.secure() == :ok end) == ""
  end

  test "files outside the data dirs keep their modes" do
    kernel = write!(Path.join(Dirs.vmlinux_install_dir(), "vmlinux-6.1"), 0o644)
    firecracker = write!(Path.join(Dirs.firecracker_install_dir(), "firecracker"), 0o755)

    capture_log(fn -> assert WorkDir.secure() == :ok end)

    assert mode(kernel) == 0o644
    assert mode(firecracker) == 0o755
  end

  test "a data dir that is not a directory refuses boot and names it" do
    File.write!(Dirs.layer_dir(), "")

    capture_log(fn ->
      assert {:error, {:work_dir, message}} = WorkDir.secure()
      assert message =~ Dirs.layer_dir()
    end)
  end
end
