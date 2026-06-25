defmodule Hyper.Img.OciLoader.UmociTest do
  use ExUnit.Case, async: true

  alias Hyper.Img.OciLoader.Umoci

  describe "asset_for/1" do
    test "maps each arch to its umoci release asset" do
      assert Umoci.asset_for(:x86_64) == "umoci.linux.amd64"
      assert Umoci.asset_for(:aarch64) == "umoci.linux.arm64"
    end
  end

  describe "asset_url/1" do
    test "points at the pinned v0.6.0 release asset" do
      assert Umoci.asset_url(:x86_64) ==
               "https://github.com/opencontainers/umoci/releases/download/v0.6.0/umoci.linux.amd64"

      assert Umoci.asset_url(:aarch64) ==
               "https://github.com/opencontainers/umoci/releases/download/v0.6.0/umoci.linux.arm64"
    end
  end

  describe "bin/0" do
    test "defaults to the redist install path for this node's arch when unconfigured" do
      # The test env sets no :umoci_path, so bin/0 resolves to the downloaded default.
      {:ok, arch} = Sys.Arch.current()

      assert Umoci.bin() ==
               Path.join(Hyper.Config.umoci_install_dir(), Umoci.asset_for(arch))
    end
  end
end
