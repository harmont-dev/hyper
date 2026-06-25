defmodule Hyper.Img.OciLoaderTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Config
  alias Hyper.Img.Db.{Blob, Repo}
  alias Hyper.Img.OciLoader
  alias Unit.Information

  describe "ext4_size/1" do
    test "floors small inputs at 16 MiB" do
      assert OciLoader.ext4_size(Information.bytes(0)) == Information.mib(16)
      assert OciLoader.ext4_size(Information.bytes(1)) == Information.mib(16)
    end

    test "scales overhead with content above the floor crossover" do
      assert OciLoader.ext4_size(Information.mib(4)) == Information.mib(16)
      assert OciLoader.ext4_size(Information.mib(64)) == Information.mib(88)
    end

    property "always a whole-MiB size that fits the content and clears the floor" do
      check all(bytes <- integer(0..Information.as_bytes(Information.gib(8)))) do
        size = Information.as_bytes(OciLoader.ext4_size(Information.bytes(bytes)))

        assert rem(size, Information.as_bytes(Information.mib(1))) == 0
        assert size >= bytes
        assert size >= Information.as_bytes(Information.mib(16))
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
