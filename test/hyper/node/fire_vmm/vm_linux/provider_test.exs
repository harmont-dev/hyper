defmodule Hyper.Node.FireVMM.VmLinux.ProviderTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.VmLinux.{Manifest, Provider}

  setup do
    dir = Path.join(System.tmp_dir!(), "vmlinux-prov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    # Use a real arch that exists in the manifest; both x86_64 and aarch64 do.
    {:ok, dir: dir, builds: Manifest.builds_for(:x86_64)}
  end

  test "install_state/2 is :not_installed when no asset files are present", %{
    dir: dir,
    builds: builds
  } do
    assert Provider.install_state(dir, builds) == {:error, :not_installed}
  end

  test "install_state/2 is :ok when every asset file is present", %{dir: dir, builds: builds} do
    for b <- builds, do: File.write!(Path.join(dir, b.asset), "kernel")
    assert Provider.install_state(dir, builds) == :ok
  end

  test "install_state/2 is :bad_install when only some asset files are present", %{
    dir: dir,
    builds: builds
  } do
    [first | _] = builds
    File.write!(Path.join(dir, first.asset), "kernel")
    assert Provider.install_state(dir, builds) == {:error, :bad_install}
  end

  test "default_path/1 resolves under the configured install dir", %{builds: _} do
    assert {:ok, path} = Provider.default_path(:x86_64)
    assert path == Path.join(Hyper.Config.vmlinux_install_dir(), "vmlinux-x86_64-6.1")
  end

  test "path/1 rejects an unknown build name" do
    assert Provider.path("nope") == {:error, {:unknown_build, "nope"}}
  end
end
