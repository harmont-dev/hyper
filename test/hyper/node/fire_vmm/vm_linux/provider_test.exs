defmodule Hyper.Node.FireVMM.VmLinux.ProviderTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.VmLinux.{Manifest, Provider}

  setup do
    dir = Path.join(System.tmp_dir!(), "vmlinux-prov-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    # Use a real arch that exists in the manifest; both x86_64 and aarch64 do.
    {:ok, dir: dir, builds: Manifest.builds_for(:x86_64), owner: File.stat!(dir).uid}
  end

  test "install_state/3 is :not_installed when no asset files are present", %{
    dir: dir,
    builds: builds,
    owner: owner
  } do
    assert Provider.install_state(dir, builds, owner) == {:error, :not_installed}
  end

  test "install_state/3 is :ok when every asset file is present with its manifest hash", %{
    dir: dir,
    builds: builds,
    owner: owner
  } do
    builds = Enum.map(builds, &write_asset(dir, &1))
    assert Provider.install_state(dir, builds, owner) == :ok
  end

  test "install_state/3 is :bad_install when only some asset files are present", %{
    dir: dir,
    builds: builds,
    owner: owner
  } do
    assert length(builds) > 1
    [first | rest] = builds

    assert Provider.install_state(dir, [write_asset(dir, first) | rest], owner) ==
             {:error, :bad_install}
  end

  test "install_state/3 is :not_installed when every present file has a stale hash", %{
    dir: dir,
    builds: builds,
    owner: owner
  } do
    # A manifest bump leaves the previous release's kernels at the same asset
    # paths; they must not count as installed or nodes would boot old kernels.
    for b <- builds, do: File.write!(Path.join(dir, b.asset), "stale #{b.asset}")
    assert Provider.install_state(dir, builds, owner) == {:error, :not_installed}
  end

  test "install_state/3 is :bad_install when some present files have a stale hash", %{
    dir: dir,
    builds: builds,
    owner: owner
  } do
    assert length(builds) > 1
    [first | rest] = builds
    builds = [write_asset(dir, first) | rest]
    for b <- rest, do: File.write!(Path.join(dir, b.asset), "stale #{b.asset}")
    assert Provider.install_state(dir, builds, owner) == {:error, :bad_install}
  end

  test "install_state/3 refuses a hash-correct kernel that a jail could rewrite", %{
    dir: dir,
    builds: builds,
    owner: owner
  } do
    rows = [
      {"group-writable", 0o664, owner},
      {"other-writable", 0o646, owner},
      {"owned by another uid", 0o644, owner + 1}
    ]

    for {name, mode, expected_owner} <- rows do
      installed = Enum.map(builds, &write_asset(dir, &1))
      for b <- installed, do: File.chmod!(Path.join(dir, b.asset), mode)

      assert Provider.install_state(dir, installed, expected_owner) == {:error, :not_installed},
             name
    end
  end

  test "default_path/1 resolves under the configured install dir", %{builds: _} do
    assert {:ok, path} = Provider.default_path(:x86_64)
    assert path == Path.join(Hyper.Cfg.Dirs.vmlinux_install_dir(), "vmlinux-x86_64-6.1")
  end

  test "path/1 resolves a known build under the install dir" do
    assert Provider.path("x86_64-6.1") ==
             {:ok, Path.join(Hyper.Cfg.Dirs.vmlinux_install_dir(), "vmlinux-x86_64-6.1")}
  end

  test "path/1 rejects an unknown build name" do
    assert Provider.path("nope") == {:error, {:unknown_build, "nope"}}
  end

  # Writes fabricated content for `build` under `dir` and returns the build
  # with its sha256 matching that content, so install_state/3 sees it as a
  # faithful install.
  defp write_asset(dir, build) do
    content = "kernel #{build.asset}"
    path = Path.join(dir, build.asset)
    File.write!(path, content)
    File.chmod!(path, 0o644)
    %{build | sha256: Base.encode16(:crypto.hash(:sha256, content), case: :lower)}
  end

  test "usable?/2 takes a kernel owned by root or the node user that no one else can write",
       %{dir: dir, owner: owner} do
    path = Path.join(dir, "vmlinux-probe")
    File.write!(path, "kernel")

    rows = [
      {0o644, owner, true},
      {0o644, owner + 1, false},
      {0o664, owner, false},
      {0o646, owner, false}
    ]

    for {mode, as, usable} <- rows do
      File.chmod!(path, mode)
      assert Provider.usable?(path, as) == usable, inspect({mode, as})
    end
  end
end
