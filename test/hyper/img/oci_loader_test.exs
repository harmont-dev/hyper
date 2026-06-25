defmodule Hyper.Img.OciLoaderTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Config
  alias Hyper.Img.Db.{Blob, Repo}
  alias Hyper.Img.OciLoader
  alias Unit.Information

  describe "ext4_params/2" do
    test "provisions inode headroom above the file count" do
      {_size, inodes} = OciLoader.ext4_params(Information.mib(100), 10_000)
      assert inodes > 10_000
    end

    property "size is a whole MiB that holds the content and the inode table" do
      check all(
              bytes <- integer(0..Information.as_bytes(Information.gib(8))),
              files <- integer(0..500_000)
            ) do
        {size, inodes} = OciLoader.ext4_params(Information.bytes(bytes), files)
        size_b = Information.as_bytes(size)

        assert inodes >= files
        assert rem(size_b, Information.as_bytes(Information.mib(1))) == 0
        assert size_b >= bytes + inodes * 256
      end
    end
  end

  # Opt-in: needs skopeo, umoci, mke2fs, network, and Postgres. mix test --include external
  @tag :external
  test "load/1 publishes a busybox base image to the store and DB" do
    assert OciLoader.test_system() == :ok

    assert {:ok, id} = OciLoader.load("docker.io/library/busybox:1.36")

    path = Path.join(Config.layer_dir(), "layer_#{id}.img")
    assert File.exists?(path)
    assert File.stat!(path).size > 0

    assert %Blob{kind: :base} = Repo.get(Blob, id)
    assert Repo.get(Blob, id).size == File.stat!(path).size
  end
end
