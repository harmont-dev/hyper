defmodule Hyper.Img.OciLoader.ParamsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Img.OciLoader.Params

  @mib 1024 * 1024

  describe "source/1" do
    test "prefixes a valid ref with the docker transport" do
      assert Params.source("docker.io/library/alpine:3.19") ==
               {:ok, "docker://docker.io/library/alpine:3.19"}

      assert Params.source("ghcr.io/foo/bar@sha256:abc") ==
               {:ok, "docker://ghcr.io/foo/bar@sha256:abc"}
    end

    test "rejects empty, blank, or whitespace-bearing refs" do
      assert Params.source("") == {:error, :invalid_ref}
      assert Params.source("   ") == {:error, :invalid_ref}
      assert Params.source("alpine 3.19") == {:error, :invalid_ref}
      assert Params.source("alpine\n") == {:error, :invalid_ref}
    end
  end

  describe "goarch/1" do
    test "maps Hyper arches to Go/OCI arch names" do
      assert Params.goarch(:x86_64) == "amd64"
      assert Params.goarch(:aarch64) == "arm64"
    end
  end

  describe "ext4_bytes/1" do
    test "floors small inputs at 16 MiB" do
      assert Params.ext4_bytes(0) == 16 * @mib
      assert Params.ext4_bytes(1) == 16 * @mib
    end

    test "leaves headroom above the content size, rounded up to a whole MiB" do
      size = Params.ext4_bytes(100 * @mib)
      assert size > 100 * @mib
      assert rem(size, @mib) == 0
    end

    test "scales overhead with content above the floor crossover" do
      # content small enough that 1.25x + 8 MiB stays under the 16 MiB floor
      assert Params.ext4_bytes(4 * @mib) == 16 * @mib
      # content past the crossover gets proportional slack, not the floor
      assert Params.ext4_bytes(64 * @mib) == 88 * @mib
    end

    property "always a whole-MiB size that fits the content and clears the floor" do
      check all content <- integer(0..(8 * 1024 * @mib)) do
        size = Params.ext4_bytes(content)
        assert rem(size, @mib) == 0
        assert size >= content
        assert size >= 16 * @mib
      end
    end
  end
end
