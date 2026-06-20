defmodule Sys.Linux.Proc.DiskstatsTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.Diskstats
  alias Sys.Linux.Proc.Diskstats.Device

  # A representative slice of a real `/proc/diskstats`: a loop device, a whole disk
  # with two partitions, an optical drive, two network block devices, and a device
  # mapper node. Enough device *kinds* to exercise the parser without pinning the
  # test to one machine's full device list.
  @diskstats """
     7       0 loop0 134102 0 13140498 217041 0 0 0 0 0 1336814 217041 0 0 0 0 0 0
   253       0 vda 91328226 27622106 5543880870 8503116 138999764 190022891 8316005346 26346373 0 10151166 39309214 6398723 0 17796273080 2661162 66530576 1798561
   253       1 vda1 2250 9204 63092 194 2 0 2 0 0 115 235 11 0 11373032 40 0 0
   253       2 vda2 91324557 27612902 5543772748 8502838 138999750 190022883 8316005240 26346372 0 28081885 37510333 6398712 0 17784900048 2661122 0 0
    11       0 sr0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
    43       0 nbd0 236 10 11650 164 8 0 0 5 0 157 169 0 0 0 0 8 0
    43      64 nbd2 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0
   252       0 dm-0 173 0 9312 12 60 0 4830 13 0 7 25 0 0 0 0 0 0
  """

  defp find(devices, name), do: Enum.find(devices, &(&1.name == name))

  describe "parse/1" do
    test "converts sectors_read/sectors_written into bytes (x512)" do
      devices = Diskstats.parse(@diskstats)

      vda = find(devices, "vda")
      assert vda.read_bytes == 5_543_880_870 * 512
      assert vda.write_bytes == 8_316_005_346 * 512

      loop0 = find(devices, "loop0")
      assert loop0.read_bytes == 13_140_498 * 512
      assert loop0.write_bytes == 0

      dm0 = find(devices, "dm-0")
      assert dm0.read_bytes == 9_312 * 512
      assert dm0.write_bytes == 4_830 * 512
    end

    test "returns every device, including partitions and virtual devices (no filtering)" do
      names = @diskstats |> Diskstats.parse() |> Enum.map(& &1.name)

      assert "vda" in names
      assert "vda1" in names
      assert "vda2" in names
      assert "loop0" in names
      assert "nbd0" in names
      assert "dm-0" in names
      assert "sr0" in names
    end

    test "an idle device parses to zero bytes" do
      nbd2 = @diskstats |> Diskstats.parse() |> find("nbd2")

      assert nbd2.read_bytes == 0
      assert nbd2.write_bytes == 0
    end

    test "parses a minimal synthetic line" do
      assert [%Device{name: "sda", read_bytes: read, write_bytes: write}] =
               Diskstats.parse(" 8 0 sda 1 2 100 3 4 5 200 6 7 8\n")

      assert read == 100 * 512
      assert write == 200 * 512
    end

    test "skips lines too short to carry sector counts" do
      assert Diskstats.parse("8 0 sda 1 2 3\n") == []
    end
  end

  describe "read/0" do
    test "reads the live /proc/diskstats into Device structs" do
      assert {:ok, devices} = Diskstats.read()
      assert Enum.all?(devices, &match?(%Device{}, &1))
    end
  end
end
