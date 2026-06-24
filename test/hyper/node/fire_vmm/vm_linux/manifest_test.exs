defmodule Hyper.Node.FireVMM.VmLinux.ManifestTest do
  use ExUnit.Case, async: true

  alias Hyper.Node.FireVMM.VmLinux.Manifest
  alias Hyper.Node.FireVMM.VmLinux.Manifest.Build

  test "builds_for/1 returns only builds for the given arch, with atom archs" do
    x86 = Manifest.builds_for(:x86_64)
    assert Enum.all?(x86, &(&1.arch == :x86_64))
    assert "x86_64-6.1" in Enum.map(x86, & &1.name)
    assert Enum.all?(Manifest.builds_for(:aarch64), &(&1.arch == :aarch64))
  end

  test "fetch/1 finds a build by name and rejects unknown names" do
    assert {:ok, %Build{asset: "vmlinux-x86_64-6.1", arch: :x86_64}} =
             Manifest.fetch("x86_64-6.1")

    assert Manifest.fetch("does-not-exist") == :error
  end

  test "default_for/1 selects the highest-version build for the arch" do
    assert %Build{name: "x86_64-6.1"} = Manifest.default_for(:x86_64)
    assert %Build{name: "aarch64-6.1"} = Manifest.default_for(:aarch64)
  end

  test "asset_url/1 points at the pinned release tag" do
    build = Manifest.default_for(:x86_64)

    assert Manifest.asset_url(build) ==
             "https://github.com/harmont-dev/hyper-vmlinux/releases/download/" <>
               "release-54d6c3f843c01fb55107a024cca5bf60af235c42/vmlinux-x86_64-6.1"
  end
end
