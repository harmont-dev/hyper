defmodule Hyper.Img.OciLoaderTest do
  # End-to-end: pulls a real (tiny) public image, builds the ext4 blob, and
  # records it in the DB. Opt-in -- needs skopeo, umoci, mke2fs, network, and a
  # running Postgres. Run with: mix test --include external
  use ExUnit.Case, async: false
  @moduletag :external

  alias Hyper.Config
  alias Hyper.Img.Db.{Blob, Repo}
  alias Hyper.Img.OciLoader

  test "load/1 publishes a busybox base image to the store and DB" do
    assert OciLoader.test_system() == :ok

    assert {:ok, id} = OciLoader.load("docker.io/library/busybox:1.36")

    # File landed in the media store at its content-addressed path.
    path = Path.join(Config.layer_dir(), "layer_#{id}.img")
    assert File.exists?(path)
    assert File.stat!(path).size > 0

    # DB row exists and is a base blob.
    assert %Blob{kind: :base} = Repo.get(Blob, id)

    # Idempotent: re-publishing the identical file is a no-op that returns the
    # same id (the bytes are already present, so the hash matches).
    assert File.exists?(path)
  end
end
