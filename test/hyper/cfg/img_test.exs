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

  property "metadata covers the kernel's 48 bytes per data block, and never drops below 1 GiB" do
    check all(blocks <- integer(0..Bitwise.bsl(1, 32))) do
      data = Information.bytes(blocks * Img.thin_block_sectors() * 512)
      meta = Information.as_bytes(Img.thin_pool_meta_size(data))

      assert meta >= 48 * blocks
      assert meta >= Information.as_bytes(Information.gib(1))
    end
  end
end
