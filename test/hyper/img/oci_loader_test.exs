defmodule Hyper.Img.OciLoaderTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Config
  alias Hyper.Img.Db.{Blob, Repo}
  alias Hyper.Img.OciLoader

  @mib 1024 * 1024

  describe "source/1" do
    test "prefixes a valid ref with the docker transport" do
      assert OciLoader.source("docker.io/library/alpine:3.19") ==
               {:ok, "docker://docker.io/library/alpine:3.19"}

      assert OciLoader.source("ghcr.io/foo/bar@sha256:abc") ==
               {:ok, "docker://ghcr.io/foo/bar@sha256:abc"}
    end

    test "rejects empty, blank, or whitespace-bearing refs" do
      assert OciLoader.source("") == {:error, :invalid_ref}
      assert OciLoader.source("   ") == {:error, :invalid_ref}
      assert OciLoader.source("alpine 3.19") == {:error, :invalid_ref}
      assert OciLoader.source("alpine\n") == {:error, :invalid_ref}
    end
  end

  describe "goarch/1" do
    test "maps Hyper arches to Go/OCI arch names" do
      assert OciLoader.goarch(:x86_64) == "amd64"
      assert OciLoader.goarch(:aarch64) == "arm64"
    end
  end

  describe "ext4_bytes/1" do
    test "floors small inputs at 16 MiB" do
      assert OciLoader.ext4_bytes(0) == 16 * @mib
      assert OciLoader.ext4_bytes(1) == 16 * @mib
    end

    test "leaves headroom above the content size, rounded up to a whole MiB" do
      size = OciLoader.ext4_bytes(100 * @mib)
      assert size > 100 * @mib
      assert rem(size, @mib) == 0
    end

    test "scales overhead with content above the floor crossover" do
      # content small enough that 1.25x + 8 MiB stays under the 16 MiB floor
      assert OciLoader.ext4_bytes(4 * @mib) == 16 * @mib
      # content past the crossover gets proportional slack, not the floor
      assert OciLoader.ext4_bytes(64 * @mib) == 88 * @mib
    end

    property "always a whole-MiB size that fits the content and clears the floor" do
      check all(content <- integer(0..(8 * 1024 * @mib))) do
        size = OciLoader.ext4_bytes(content)
        assert rem(size, @mib) == 0
        assert size >= content
        assert size >= 16 * @mib
      end
    end
  end

  # End-to-end: pulls a real (tiny) public image, builds the ext4 blob, and
  # records it in the DB. Opt-in -- needs skopeo, umoci, mke2fs, network, and a
  # running Postgres. Run with: mix test --include external
  @tag :external
  test "load/1 publishes a busybox base image to the store and DB" do
    assert OciLoader.test_system() == :ok

    assert {:ok, id} = OciLoader.load("docker.io/library/busybox:1.36")

    # File landed in the media store at its content-addressed path.
    path = Path.join(Config.layer_dir(), "layer_#{id}.img")
    assert File.exists?(path)
    assert File.stat!(path).size > 0

    # DB row exists and is a base blob.
    assert %Blob{kind: :base} = Repo.get(Blob, id)

    # The recorded blob size matches the published file exactly.
    assert Repo.get(Blob, id).size == File.stat!(path).size
  end
end
