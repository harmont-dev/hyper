defmodule Sys.Linux.Proc.NetDevTest do
  use ExUnit.Case, async: true

  alias Sys.Linux.Proc.NetDev
  alias Sys.Linux.Proc.NetDev.Interface

  # A representative slice of a real `/proc/net/dev`: the two header rows, loopback,
  # a physical NIC, a docker bridge, a custom bridge, and a tailscale tunnel. Enough
  # interface *kinds* to exercise the parser without pinning to one host's full list.
  @net_dev """
  Inter-|   Receive                                                |  Transmit
   face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
      lo: 27547634288 74913229    0    0    0     0          0         0 27547634288 74913229    0    0    0     0       0          0
  enp1s0: 187188513509 68447977    0    0    0     0          0         0 112751842436 64224487    0    0    0     0       0          0
  docker0: 133442036 1319090    0    0    0     0          0         0 40568947840 2153890    0    0    0     0       0          0
  br-819027fabbaf: 2952805132 16242196    0    0    0     0          0         0 92249083852 17063615    0    0    0     0       0          0
  tailscale0: 66322494  516593    0    0    0     0          0         0 338546045  458517    0    0    0     0       0          0
  """

  defp find(interfaces, name), do: Enum.find(interfaces, &(&1.name == name))

  describe "parse/1" do
    test "skips both header rows and parses one Interface per data line" do
      interfaces = NetDev.parse(@net_dev)

      assert length(interfaces) == 5
      refute Enum.any?(interfaces, &(&1.name in ["Inter-|", "face"]))
    end

    test "reads receive bytes (col 1) and transmit bytes (col 9)" do
      interfaces = NetDev.parse(@net_dev)

      enp1s0 = find(interfaces, "enp1s0")
      assert enp1s0.rx_bytes == 187_188_513_509
      assert enp1s0.tx_bytes == 112_751_842_436

      docker0 = find(interfaces, "docker0")
      assert docker0.rx_bytes == 133_442_036
      assert docker0.tx_bytes == 40_568_947_840
    end

    test "returns every interface, loopback and virtual included (no filtering)" do
      names = @net_dev |> NetDev.parse() |> Enum.map(& &1.name)

      assert "lo" in names
      assert "enp1s0" in names
      assert "docker0" in names
      assert "br-819027fabbaf" in names
      assert "tailscale0" in names
    end

    test "keeps an interface name that itself contains a colon (IP alias)" do
      assert [%Interface{name: "eth0:0", rx_bytes: 1, tx_bytes: 9}] =
               NetDev.parse("  eth0:0: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16\n")
    end

    test "skips a line too short to carry a transmit-bytes column" do
      assert NetDev.parse("eth0: 1 2 3\n") == []
    end
  end

  describe "read/0" do
    test "reads the live /proc/net/dev into Interface structs" do
      assert {:ok, interfaces} = NetDev.read()
      assert Enum.all?(interfaces, &match?(%Interface{}, &1))
    end
  end
end
