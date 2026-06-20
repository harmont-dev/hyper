defmodule Sys.Linux.Proc.MeminfoTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.Meminfo
  alias Sys.Linux.Proc.Meminfo.Snapshot
  alias Unit.Information

  # A verbatim `/proc/meminfo` capture from a real x86-64 host. Used to pin the
  # parser against the actual file format (units, alignment, mixed kB/no-kB
  # lines, and very large values like VmallocTotal).
  @real_meminfo """
  MemTotal:       16370012 kB
  MemFree:         1643856 kB
  MemAvailable:    5220048 kB
  Buffers:          716556 kB
  Cached:          1331380 kB
  SwapCached:       149340 kB
  Active:          7831484 kB
  Inactive:        3866760 kB
  Active(anon):    7617764 kB
  Inactive(anon):  2278304 kB
  Active(file):     213720 kB
  Inactive(file):  1588456 kB
  Unevictable:       27876 kB
  Mlocked:           27876 kB
  SwapTotal:       8388604 kB
  SwapFree:         906240 kB
  Zswap:                 0 kB
  Zswapped:              0 kB
  Dirty:              2192 kB
  Writeback:             0 kB
  AnonPages:       9528960 kB
  Mapped:           676788 kB
  Shmem:            236944 kB
  KReclaimable:    2115060 kB
  Slab:            2551592 kB
  SReclaimable:    2115060 kB
  SUnreclaim:       436532 kB
  KernelStack:       29800 kB
  PageTables:       214552 kB
  SecPageTables:         0 kB
  NFS_Unstable:          0 kB
  Bounce:                0 kB
  WritebackTmp:          0 kB
  CommitLimit:    16573608 kB
  Committed_AS:   17194732 kB
  VmallocTotal:   13743895347199 kB
  VmallocUsed:       68868 kB
  VmallocChunk:          0 kB
  Percpu:             4064 kB
  HardwareCorrupted:     0 kB
  AnonHugePages:         0 kB
  ShmemHugePages:        0 kB
  ShmemPmdMapped:        0 kB
  FileHugePages:         0 kB
  FilePmdMapped:         0 kB
  Unaccepted:            0 kB
  HugePages_Total:       0
  HugePages_Free:        0
  HugePages_Rsvd:        0
  HugePages_Surp:        0
  Hugepagesize:       2048 kB
  Hugetlb:               0 kB
  DirectMap4k:      516160 kB
  DirectMap2M:     9963520 kB
  DirectMap1G:     8388608 kB
  """

  defp bytes(snapshot_field), do: Information.as_bytes(snapshot_field)

  describe "parse/1" do
    test "extracts every Snapshot field from a real /proc/meminfo capture" do
      snap = Meminfo.parse(@real_meminfo)

      assert %Snapshot{} = snap
      assert bytes(snap.total) == 16_370_012 * 1024
      assert bytes(snap.available) == 5_220_048 * 1024
      assert bytes(snap.free) == 1_643_856 * 1024
      assert bytes(snap.buffers) == 716_556 * 1024
      assert bytes(snap.cached) == 1_331_380 * 1024
    end

    test "ignores no-kB lines (HugePages_*) and tolerates very large values" do
      # The capture contains HugePages_* lines without a `kB` suffix and a
      # 14-digit VmallocTotal; neither must break parsing of the real fields.
      snap = Meminfo.parse(@real_meminfo)

      assert bytes(snap.total) == 16_370_012 * 1024
    end

    test "parses a minimal payload carrying only the required keys" do
      payload = """
      MemTotal:       16384 kB
      MemFree:         1024 kB
      MemAvailable:    8192 kB
      Buffers:          256 kB
      Cached:          2048 kB
      """

      snap = Meminfo.parse(payload)

      assert bytes(snap.total) == 16_384 * 1024
      assert bytes(snap.available) == 8_192 * 1024
      assert bytes(snap.free) == 1_024 * 1024
      assert bytes(snap.buffers) == 256 * 1024
      assert bytes(snap.cached) == 2_048 * 1024
    end

    test "raises when a required field is absent" do
      # MemAvailable removed - parse must fail loudly rather than fabricate a value.
      payload = """
      MemTotal:       16384 kB
      MemFree:         1024 kB
      Buffers:          256 kB
      Cached:          2048 kB
      """

      assert_raise KeyError, fn -> Meminfo.parse(payload) end
    end
  end

  describe "read/0" do
    test "reads and parses the live /proc/meminfo into a sane Snapshot" do
      assert {:ok, %Snapshot{} = snap} = Meminfo.read()

      assert bytes(snap.total) > 0
      assert bytes(snap.available) <= bytes(snap.total)
      assert bytes(snap.free) <= bytes(snap.total)
    end
  end
end
