defmodule Hyper.Img.OciLoaderTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Hyper.Cfg.Dirs
  alias Hyper.Img.Db.{Blob, Repo}
  alias Hyper.Img.OciLoader
  alias Unit.Information

  describe "ext4_params/2" do
    test "provisions inode headroom above the file count" do
      {_size, inodes} = OciLoader.ext4_params(Information.mib(100), 10_000)
      assert inodes > 10_000
    end

    property "size is a whole MiB holding the content, its slack, the journal and the inode table" do
      check all(
              bytes <- integer(0..Information.as_bytes(Information.gib(8))),
              files <- integer(0..500_000)
            ) do
        {size, inodes} = OciLoader.ext4_params(Information.bytes(bytes), files)
        size_b = Information.as_bytes(size)
        journal = Information.as_bytes(Information.mib(64))

        assert inodes >= files
        assert rem(size_b, Information.as_bytes(Information.mib(1))) == 0
        assert size_b >= bytes + div(bytes, 4) + journal + inodes * 256
      end
    end

    property "free space before the content lands holds two journals, as mke2fs requires" do
      check all(
              bytes <- integer(0..Information.as_bytes(Information.gib(8))),
              files <- integer(0..500_000)
            ) do
        {size, inodes} = OciLoader.ext4_params(Information.bytes(bytes), files)
        journal = Information.as_bytes(Information.mib(64))

        assert Information.as_bytes(size) >= 2 * journal + inodes * 256
      end
    end

    property "every 128 MiB block group holds an inode per 16 KiB, a density online growth keeps" do
      check all(
              bytes <- integer(0..Information.as_bytes(Information.gib(8))),
              files <- integer(0..500_000)
            ) do
        {size, inodes} = OciLoader.ext4_params(Information.bytes(bytes), files)
        group = Information.as_bytes(Information.mib(128))
        groups = div(Information.as_bytes(size) + group - 1, group)

        assert div(inodes + groups - 1, groups) * Information.as_bytes(Information.kib(16)) >=
                 group
      end
    end
  end

  # Opt-in: needs skopeo, umoci, mke2fs, network, and Postgres. mix test --include external
  @tag :external
  test "load/1 publishes a busybox base image to the store and DB" do
    assert OciLoader.test_system() == :ok

    assert {:ok, id} = OciLoader.load("docker.io/library/busybox:1.36")

    path = Path.join(Dirs.layer_dir(), "layer_#{id}.img")
    assert File.exists?(path)
    assert File.stat!(path).size > 0

    assert %Blob{kind: :base} = Repo.get(Blob, id)
    assert Repo.get(Blob, id).size == File.stat!(path).size
  end

  @tag :external
  test "a loaded image can grow online to the largest instance disk" do
    assert {:ok, id} = OciLoader.load("docker.io/library/busybox:1.36")
    path = Path.join(Dirs.layer_dir(), "layer_#{id}.img")

    stats = debugfs!(path, "stats")
    block = field!(stats, "Block size")
    blocks = field!(stats, "Block count")
    per_group = field!(stats, "Blocks per group")
    per_gdt_block = div(block, field!(stats, "Group descriptor size"))
    gdt_blocks = div(div(blocks + per_group - 1, per_group) + per_gdt_block - 1, per_gdt_block)
    reserved = field!(stats, "Reserved GDT blocks")

    largest =
      Hyper.Vm.Instance.types()
      |> Enum.map(&Information.as_bytes(Hyper.Vm.Instance.spec(&1).disk))
      |> Enum.max()

    assert block == 4096
    assert (gdt_blocks + reserved) * per_gdt_block * per_group * block >= largest

    assert field!(stats, "Inodes per group") * Information.as_bytes(Information.kib(16)) >=
             per_group * block

    assert field!(debugfs!(path, "stat <8>"), "Size") >=
             Information.as_bytes(Information.mib(64))
  end

  defp debugfs!(path, request) do
    {out, 0} =
      System.cmd(Hyper.Cfg.Tools.debugfs(), ["-R", request, path], stderr_to_stdout: true)

    out
  end

  defp field!(text, name) do
    [_, value] = Regex.run(~r/\b#{name}:\s+(\d+)/, text)
    String.to_integer(value)
  end
end
