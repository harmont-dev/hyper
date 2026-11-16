defmodule Hyper.Node.VmlinuxTest do
  @moduledoc """
  Boot-time verdict of `Hyper.Node.Vmlinux.test_system/0` on an
  operator-configured kernel path.

  Law: the node's boot check and the setuid helper agree. `test_system/0`
  exists so "a misconfigured node aborts at boot instead of failing the first
  VM launch", so it must refuse exactly the kernels the helper's
  `KernelImage::open` refuses (absent, non-regular, group/other-writable,
  owned by neither root nor the node user) and accept exactly the ones it
  stages. The helper resolves symlinks before vetting the target
  (`kernel_symlink_stages_its_target`), so a symlink is judged by what it
  points at.
  """
  use ExUnit.Case, async: false

  alias Hyper.Cfg.VmLinux
  alias Hyper.Node.Vmlinux

  setup do
    dir = Path.join(System.tmp_dir!(), "vmlinux-boot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Hyper.Cfg.Toml.put_cache(%{})

    on_exit(fn ->
      Application.delete_env(:hyper, VmLinux)
      Hyper.Cfg.Toml.reload()
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  defp verdict(path) do
    Application.put_env(:hyper, VmLinux, amd64: path, aarch64: path)
    Vmlinux.test_system()
  end

  defp kernel(dir, name, mode) do
    path = Path.join(dir, name)
    File.write!(path, "kernel")
    File.chmod!(path, mode)
    path
  end

  defp link(dir, name, target) do
    path = Path.join(dir, name)
    File.ln_s!(target, path)
    path
  end

  test "refuses exactly what the helper refuses", %{dir: dir} do
    trusted = kernel(dir, "trusted", 0o644)
    loose = kernel(dir, "loose", 0o664)
    missing = Path.join(dir, "missing")
    subdir = Path.join(dir, "subdir")
    File.mkdir_p!(subdir)

    rows = [
      {"node-owned 0644", trusted, :ok},
      {"node-owned 0444", kernel(dir, "readonly", 0o444), :ok},
      {"root-owned 0644", "/etc/passwd", :ok},
      {"group-writable", loose, {:error, {:vmlinux_untrusted, loose}}},
      {"absent", missing, {:error, {:vmlinux_missing, missing}}},
      {"directory", subdir, {:error, {:vmlinux_missing, subdir}}}
    ]

    for {name, path, expected} <- rows do
      assert verdict(path) == expected, name
    end
  end

  test "a symlink is judged by its target, as the helper judges it", %{dir: dir} do
    trusted = kernel(dir, "vmlinux-6.1.1", 0o644)
    loose = kernel(dir, "vmlinux-loose", 0o666)
    to_trusted = link(dir, "vmlinux", trusted)
    to_loose = link(dir, "vmlinux-l", loose)
    to_root = link(dir, "vmlinux-root", "/etc/passwd")

    got = for path <- [to_trusted, to_root, to_loose], do: verdict(path)

    assert got == [:ok, :ok, {:error, {:vmlinux_untrusted, to_loose}}]
  end
end
