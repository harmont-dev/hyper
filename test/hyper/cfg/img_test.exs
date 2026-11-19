defmodule Hyper.Cfg.ImgTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Hyper.Cfg.Img
  alias Unit.Information

  property "the pool's data device holds the whole disk budget in whole pool blocks" do
    check all(disk_max <- integer(0..Information.as_bytes(Information.tib(64)))) do
      block = Img.thin_block_sectors() * 512
      data = Information.as_bytes(Img.thin_pool_data_size(Information.bytes(disk_max)))

      assert rem(data, block) == 0
      assert data >= disk_max
      assert data - disk_max < block
    end
  end

  property "metadata covers the kernel's 48 bytes per data block, and never drops below 2 MiB" do
    check all(blocks <- integer(0..Bitwise.bsl(1, 32))) do
      data = Information.bytes(blocks * Img.thin_block_sectors() * 512)
      meta = Information.as_bytes(Img.thin_pool_meta_size(data))

      assert meta >= 48 * blocks
      assert meta >= Information.as_bytes(Information.mib(2))
    end
  end

  test "metadata is exactly the kernel's guide, or its 2 MiB floor" do
    rows = [
      {Information.mib(64), Information.mib(2)},
      {Information.gib(4), Information.mib(3)},
      {Information.tib(2), Information.mib(1536)}
    ]

    for {data, meta} <- rows do
      assert Img.thin_pool_meta_size(data) == meta, "#{inspect(data)}"
    end
  end
end
