defmodule Sys.Linux.Proc.NetDev do
  @moduledoc """
  Parses `/proc/net/dev` into per-interface byte counters.

  The file opens with two header lines and then one line per interface:

      Inter-|   Receive  ...                  |  Transmit ...
       face |bytes  packets ...               |bytes  packets ...
      enp1s0: 187188513509 68447977 0 ...      112751842436 64224487 0 ...

  Each data line is `<ifname>: <8 receive counters> <8 transmit counters>`, where
  receive `bytes` is the 1st counter and transmit `bytes` is the 9th. Rather than
  trust the header or assume a fixed column count, a line is taken only if it
  matches `name: <digits...>`: the two header rows do not (no `name:` followed by a
  number), and an interface name may itself contain a `:` (an IP alias such as
  `eth0:0`), which a naive split on the first colon would mangle.

  Every interface is returned as-is - loopback, bridges, docker/veth, and tunnels
  included. Which interfaces count toward a metric is the caller's policy.
  """

  @path "/proc/net/dev"

  # 0-based offsets within the 16 numeric counters: receive bytes first, then the
  # other 7 receive counters, then transmit bytes.
  @rx_bytes_idx 0
  @tx_bytes_idx 8

  # Leading space, the interface name up to its trailing colon (greedy, so an alias
  # like `eth0:0` is kept whole), then the counters, which must start with a digit.
  @line_re ~r/^\s*(?<iface>\S+):\s+(?<counters>\d.*)$/

  defmodule Interface do
    @moduledoc "One `/proc/net/dev` row: an interface and its cumulative rx/tx bytes."
    @type t :: %__MODULE__{
            name: String.t(),
            rx_bytes: non_neg_integer(),
            tx_bytes: non_neg_integer()
          }
    @enforce_keys [:name, :rx_bytes, :tx_bytes]
    defstruct [:name, :rx_bytes, :tx_bytes]
  end

  @doc "Read and parse `/proc/net/dev`."
  @spec read() :: {:ok, [Interface.t()]} | {:error, File.posix()}
  def read do
    with {:ok, content} <- File.read(@path), do: {:ok, parse(content)}
  end

  @doc "Parse a `/proc/net/dev` payload into one `Interface` per interface line."
  @spec parse(String.t()) :: [Interface.t()]
  def parse(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&parse_line/1)
  end

  @spec parse_line(String.t()) :: [Interface.t()]
  defp parse_line(line) do
    case Regex.named_captures(@line_re, line) do
      %{"iface" => iface, "counters" => counters} ->
        cols = counters |> String.split() |> Enum.map(&String.to_integer/1)

        if length(cols) > @tx_bytes_idx do
          [
            %Interface{
              name: iface,
              rx_bytes: Enum.at(cols, @rx_bytes_idx),
              tx_bytes: Enum.at(cols, @tx_bytes_idx)
            }
          ]
        else
          []
        end

      nil ->
        []
    end
  end
end
